[CmdletBinding()]
param (
    $ConfigFilePath = "$PSScriptRoot\config.json",

    $StateFilePath = "$PSScriptRoot\my_collection.json",

    $FolderId = 1 ,
    
    $UserAgent = "MyPowerShellCollectionScript/1.0"
)

try {
    # 1. Setup
    if (-not (Test-Path $ConfigFilePath)) { throw "config.json not found." }
    $config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $authHeaders = @{ "Authorization" = "Discogs token=$($config.token)"; "User-Agent" = $UserAgent }
    Write-Host "Authenticated as $($config.username)"

    # 2. Load Desired State
    if (-not (Test-Path $StateFilePath)) { throw "my_collection.json not found." }
    $stateJson = Get-Content -Path $StateFilePath | ConvertFrom-Json
    
    $desiredIds = [System.Collections.Generic.HashSet[int]]@()
    $desiredArtistMap = @{}

    # Handle single-item vs array quirk
    $records = if ($stateJson.records) { @($stateJson.records) } else { @() }

    foreach ($rec in $records) {
        $null = $desiredIds.Add($rec.id)
        $desiredArtistMap[$rec.id] = $rec.artist
    }
    Write-Host "Desired State: $($desiredIds.Count) items."

    # 3. Load Actual State
    Write-Host "Fetching current collection..."
    $actualIds = [System.Collections.Generic.HashSet[int]]@()
    $actualInstances = @{} 
    $nextUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases?per_page=100"

    do {
        $response = Invoke-RestMethod -Uri $nextUrl -Headers $authHeaders -Method Get
        $releases = @($response.releases) # Force array
        if ($releases.Count -eq 0) { $nextUrl = $null } 
        else {
            foreach ($item in $releases) { 
                $null = $actualIds.Add($item.id)
                if (-not $actualInstances.ContainsKey($item.id)) {
                    $actualInstances[$item.id] = $item.instance_id
                }
            }
            $nextUrl = $response.pagination.urls.next
        }
    } while ($nextUrl)
    Write-Host "Actual State:  $($actualIds.Count) items."

    # 4. Calculate Diffs
    $toAdd = @(); $toDelete = @()
    if ($desiredIds.Count -gt 0) { $toAdd = @($desiredIds.Where({ -not $actualIds.Contains($_) })) }
    if ($actualIds.Count -gt 0) { $toDelete = @($actualIds.where({ -not $desiredIds.Contains($_) })) }

    # 5. Execute Deletes
    foreach ($id in $toDelete) {
        if (-not $actualInstances.ContainsKey($id)) {
            Write-Error " -> Ghost record detected (ID $id). Delete manually on website."
            continue
        }
        $inst = $actualInstances[$id]
        Invoke-RestMethod -Uri "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id/instances/$inst" -Headers $authHeaders -Method Delete
        Write-Host " -> DELETED ID $id"
        Start-Sleep -Seconds 1.1
    }

    # 6. Execute Adds
    foreach ($id in $toAdd) {
        $expected = $desiredArtistMap[$id]
        Write-Host "Processing ID $id..."
        
        # Validation
        $valPass = $true
        if (-not [string]::IsNullOrWhiteSpace($expected)) {
            $details = Invoke-RestMethod -Uri "https://api.discogs.com/releases/$id" -Headers $authHeaders -Method Get
            if ($details.artists_sort -notlike "*$expected*") {
                Write-Warning " -> VALIDATION FAILED: Artist mismatch ('$($details.artists_sort)' vs '$expected'). Skipping."
                $valPass = $false
            }
        }

        if ($valPass) {
            Invoke-RestMethod -Uri "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id" -Headers $authHeaders -Method Post -Body ""
            Write-Host " -> ADDED ID $id"
        }
        Start-Sleep -Seconds 1.1
    }

    Write-Host "Sync Complete!"
}
catch {
    Write-Error $_
}