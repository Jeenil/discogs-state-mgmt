[CmdletBinding()]
param ()

# --- Configuration ---
$ConfigFilePath = "$PSScriptRoot\config.json"
$StateFilePath = "$PSScriptRoot\my_collection.json"
$LogFilePath = "$PSScriptRoot\my_collection_log.json"
$FolderId = 1 # 1 = "Uncategorized" folder
$UserAgent = "MyPowerShellCollectionScript/11.1" # Incremented version

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
    $desiredIds = [System.Collections.Generic.HashSet[int]]($desiredState.records | Select-Object -ExpandProperty id)
    Write-Host "Desired State: $($desiredIds.Count) items."

    # 3. Load Actual State (from Discogs)
    Write-Host "Fetching current collection from Discogs (Folder: $FolderId)..."
    $actualIds = [System.Collections.Generic.HashSet[int]]@()
    $actualInstances = @{} # Maps: release_id -> instance_id
    $nextUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases?per_page=100"

    do {
        $response = Invoke-RestMethod -Uri $nextUrl -Headers $authHeaders -Method Get
        foreach ($item in $response.releases) { 
            $null = $actualIds.Add($item.id)
            if (-not $actualInstances.ContainsKey($item.id)) {
                $actualInstances[$item.id] = $item.instance_id
            }
        }
        $nextUrl = $response.pagination.urls.next
    } while ($nextUrl)
    Write-Host "Actual State:  $($actualIds.Count) items."

    # 4. Calculate Diffs
    $toAdd = @($desiredIds.Where({ -not $actualIds.Contains($_) }))
    $toDelete = @($actualIds.Where({ -not $desiredIds.Contains($_) }))

    # 5. Execute Deletes
    if ($toDelete.Count -gt 0) {
        Write-Host "`n--- Processing Deletes ($($toDelete.Count)) ---"
        foreach ($id in $toDelete) {
            
            # --- FIX: Check if we have an instance_id before trying to delete ---
            if (-not $actualInstances.ContainsKey($id)) {
                Write-Error " -> FAILED: Cannot find instance_id for Release $id. Skipping."
                continue # Go to the next item in the loop
            }

            $instanceId = $actualInstances[$id]
            $url = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id/instances/$instanceId"
            
            try {
                Invoke-RestMethod -Uri $url -Headers $authHeaders -Method Delete
                Write-Host " -> SUCCESS: Deleted $id (Instance: $instanceId)"
            }
            catch { Write-Error " -> FAILED to delete $id - $_" }
            Start-Sleep -Seconds 1.1 # Rate limit
        }
    }
    else { Write-Host "`n--- No items to delete ---" }

    # 6. Execute Adds
    if ($toAdd.Count -gt 0) {
        Write-Host "`n--- Processing Adds ($($toAdd.Count)) ---"
        foreach ($id in $toAdd) {
            $url = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id"
            try {
                # --- FIX: Removed -PassThru to prevent "OutFile parameter missing" error ---
                Invoke-RestMethod -Uri $url -Headers $authHeaders -Method Post -Body ""
                Write-Host " -> SUCCESS: Added $id"
            }
            catch { Write-Error " -> FAILED to add $id - $_" }
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