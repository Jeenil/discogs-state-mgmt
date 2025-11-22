[CmdletBinding()]
param ()

# --- Configuration ---
$ConfigFilePath = "$PSScriptRoot\config.json"
$StateFilePath = "$PSScriptRoot\my_collection.json"
$FolderId = 1 # 1 = "Uncategorized" folder
$UserAgent = "MyPowerShellCollectionScript/15.0"

# --- Main Script ---
try {
    # 1. Load Config
    if (-not (Test-Path $ConfigFilePath)) { throw "config.json not found." }
    $config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($config.username) -or [string]::IsNullOrWhiteSpace($config.token)) {
        throw "Config file is missing username or token."
    }
    $authHeaders = @{
        "Authorization" = "Discogs token=$($config.token)"
        "User-Agent"    = $UserAgent
    }
    Write-Host "Authenticated as $($config.username)"

    # 2. Load Desired State (from my_collection.json)
    if (-not (Test-Path $StateFilePath)) { throw "my_collection.json not found." }
    $desiredState = Get-Content -Path $StateFilePath | ConvertFrom-Json
    
    $desiredIds = [System.Collections.Generic.HashSet[int]]@()
    $desiredArtistMap = @{}

    if ($desiredState.records) {
        $desiredIds = [System.Collections.Generic.HashSet[int]]($desiredState.records | Select-Object -ExpandProperty id)
        foreach ($record in $desiredState.records) {
            # Store artist for validation later
            $desiredArtistMap[$record.id] = $record.artist
        }
    }
    Write-Host "Desired State: $($desiredIds.Count) items."

    # 3. Load Actual State (from Discogs)
    Write-Host "Fetching current collection from Discogs (Folder: $FolderId)..."
    $actualIds = [System.Collections.Generic.HashSet[int]]@()
    $actualInstances = @{} # Maps: release_id -> instance_id
    $nextUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases?per_page=100"

    do {
        $response = Invoke-RestMethod -Uri $nextUrl -Headers $authHeaders -Method Get
        
        # FIX: Force result to be an array @(), even if only 1 item returned
        $releases = @($response.releases)

        if ($releases.Count -eq 0) {
            $nextUrl = $null
        }
        else {
            foreach ($item in $releases) { 
                $null = $actualIds.Add($item.id)
                # Capture instance_id for deleting later
                if (-not $actualInstances.ContainsKey($item.id)) {
                    $actualInstances[$item.id] = $item.instance_id
                }
            }
            $nextUrl = $response.pagination.urls.next
        }
    } while ($nextUrl)
    Write-Host "Actual State:  $($actualIds.Count) items."

    # 4. Calculate Diffs
    $toAdd = @()
    if ($desiredIds.Count -gt 0) {
        $toAdd = @($desiredIds.Where({ -not $actualIds.Contains($_) }))
    }

    $toDelete = @()
    if ($actualIds.Count -gt 0) {
        $toDelete = @($actualIds.where({ -not $desiredIds.Contains($_) }))
    }

    # 5. Execute Deletes
    if ($toDelete.Count -gt 0) {
        Write-Host "`n--- Processing Deletes ($($toDelete.Count)) ---"
        foreach ($id in $toDelete) {
            # Check for "Ghost" records
            if (-not $actualInstances.ContainsKey($id)) {
                Write-Error " -> FAILED: Cannot find instance_id for Release $id. (This is likely a 'ghost' record. Delete it manually on Discogs.com)."
                continue
            }
            
            $instanceId = $actualInstances[$id]
            $url = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id/instances/$instanceId"
            
            try {
                Invoke-RestMethod -Uri $url -Headers $authHeaders -Method Delete
                Write-Host " -> SUCCESS: Deleted $id (Instance: $instanceId)"
            }
            catch { Write-Error " -> FAILED to delete $id $_" }
            Start-Sleep -Seconds 1.1 # Rate limit
        }
    }
    else { Write-Host "`n--- No items to delete ---" }

    # 6. Execute Adds
    if ($toAdd.Count -gt 0) {
        Write-Host "`n--- Processing Adds ($($toAdd.Count)) ---"
        foreach ($id in $toAdd) {
            $expectedArtist = $desiredArtistMap[$id]
            Write-Host "Attempting to add ID $id..."
            $validationPassed = $false
            
            try {
                # Fetch details to validate Artist Name
                $releaseUrl = "https://api.discogs.com/releases/$id"
                $releaseDetails = Invoke-RestMethod -Uri $releaseUrl -Headers $authHeaders -Method Get
                $actualArtist = $releaseDetails.artists_sort

                if (-not [string]::IsNullOrWhiteSpace($expectedArtist)) {
                    Write-Host " -> Validating artist: '$expectedArtist'..."
                    if ($actualArtist -like "*$expectedArtist*") {
                        Write-Host " -> Validation SUCCESS: '$actualArtist' matches '$expectedArtist'."
                        $validationPassed = $true
                    }
                    else {
                        Write-Warning " -> VALIDATION FAILED: ID $id is for artist '$actualArtist', not '$expectedArtist'. Skipping add."
                    }
                }
                else {
                    Write-Warning " -> No artist found in state file for ID $id. Skipping validation."
                    $validationPassed = $true 
                }

                if ($validationPassed) {
                    $addUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id"
                    try {
                        Invoke-RestMethod -Uri $addUrl -Headers $authHeaders -Method Post -Body ""
                        Write-Host " -> SUCCESS: Added $id"
                    }
                    catch { Write-Error " -> FAILED to add $id $_" }
                }
            }
            catch {
                Write-Error " -> FAILED to get release details for $id. Skipping add. Error: $_"
            }
            Start-Sleep -Seconds 1.1 # Rate limit
        }
    }
    else { Write-Host "`n--- No items to add ---" }

    Write-Host "`nSync complete!"

}
catch {
    Write-Error "Critical Script Failure: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}