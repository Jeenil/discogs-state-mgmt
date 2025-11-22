<#
.SYNOPSIS
    Synchronizes the local state file with the Discogs API.

.DESCRIPTION
    This script serves as the "Engine" for the declarative sync process.
    1. Reads the local 'my_collection.json' file (Desired State).
    2. Fetches the current collection from Discogs (Actual State).
    3. Calculates the difference (Diff).
    4. Deletes items from Discogs that are not in the local file.
    5. Adds items to Discogs that are in the local file (with Artist validation).

.PARAMETER ConfigFilePath
    Path to the config.json file containing your Discogs Username and Token.
    Defaults to 'config.json' in the script directory.

.PARAMETER StateFilePath
    Path to the my_collection.json file containing your desired records.
    Defaults to 'my_collection.json' in the script directory.

.PARAMETER FolderId
    The Discogs Folder ID to sync. 
    Defaults to 1 (Uncategorized). 0 is the "All" folder (which cannot be added to).

.PARAMETER UserAgent
    The User-Agent string sent to the Discogs API.

.EXAMPLE
    .\Sync-Collection.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigFilePath = "$PSScriptRoot\config.json",

    [Parameter(Mandatory = $false)]
    [string]$StateFilePath = "$PSScriptRoot\my_collection.json",

    [Parameter(Mandatory = $false)]
    [int]$FolderId = 1,
    
    [Parameter(Mandatory = $false)]
    [string]$UserAgent = "MyPowerShellCollectionScript/21.0"
)

try {
    # --------------------------------------------------------------------------
    # 1. SETUP & AUTHENTICATION
    # --------------------------------------------------------------------------
    if (-not (Test-Path $ConfigFilePath)) { throw "config.json not found at $ConfigFilePath" }
    
    $config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    
    # Header required for all Discogs API requests
    $authHeaders = @{ 
        "Authorization" = "Discogs token=$($config.token)"; 
        "User-Agent"    = $UserAgent 
    }
    Write-Host "Authenticated as $($config.username)"

    # --------------------------------------------------------------------------
    # 2. LOAD DESIRED STATE (Local File)
    # --------------------------------------------------------------------------
    if (-not (Test-Path $StateFilePath)) { throw "my_collection.json not found at $StateFilePath" }
    
    $stateJson = Get-Content -Path $StateFilePath | ConvertFrom-Json
    
    # Use HashSet for high-performance lookups
    $desiredIds = [System.Collections.Generic.HashSet[int]]@()
    $desiredArtistMap = @{}

    # PowerShell Quirk: If JSON has 1 item, it's an Object. If >1, it's an Array.
    # We wrap it in @() to force it to always be an array.
    $records = if ($stateJson.records) { @($stateJson.records) } else { @() }

    foreach ($rec in $records) {
        $null = $desiredIds.Add($rec.id)
        # Store artist name for validation during the "Add" phase
        $desiredArtistMap[$rec.id] = $rec.artist
    }
    Write-Host "Desired State: $($desiredIds.Count) items found in file."

    # --------------------------------------------------------------------------
    # 3. LOAD ACTUAL STATE (Discogs API)
    # --------------------------------------------------------------------------
    Write-Host "Fetching current collection from Discogs..."
    
    $actualIds = [System.Collections.Generic.HashSet[int]]@()
    $actualInstances = @{} # Map: ReleaseID -> InstanceID (Required for Deletion)
    
    # API Pagination Loop
    $nextUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases?per_page=100"

    do {
        $response = Invoke-RestMethod -Uri $nextUrl -Headers $authHeaders -Method Get
        
        # Force array to prevent single-item bugs
        $releases = @($response.releases) 
        
        if ($releases.Count -eq 0) { 
            $nextUrl = $null 
        } 
        else {
            foreach ($item in $releases) { 
                $null = $actualIds.Add($item.id)
                # We need the 'instance_id' to delete items later.
                # Only store the first instance if duplicates exist.
                if (-not $actualInstances.ContainsKey($item.id)) {
                    $actualInstances[$item.id] = $item.instance_id
                }
            }
            $nextUrl = $response.pagination.urls.next
        }
    } while ($nextUrl)
    Write-Host "Actual State:  $($actualIds.Count) items found on Discogs."

    # --------------------------------------------------------------------------
    # 4. CALCULATE DIFFS
    # --------------------------------------------------------------------------
    $toAdd = @()
    $toDelete = @()

    # Compare the two HashSets
    if ($desiredIds.Count -gt 0) { 
        $toAdd = @($desiredIds.Where({ -not $actualIds.Contains($_) })) 
    }
    if ($actualIds.Count -gt 0) { 
        $toDelete = @($actualIds.where({ -not $desiredIds.Contains($_) })) 
    }

    # --------------------------------------------------------------------------
    # 5. EXECUTE DELETES
    # --------------------------------------------------------------------------
    if ($toDelete.Count -gt 0) {
        Write-Host "`n--- Processing Deletes ($($toDelete.Count)) ---"
        foreach ($id in $toDelete) {
            # Check for "Ghost Records" (Items that exist but have no instance_id)
            if (-not $actualInstances.ContainsKey($id)) {
                Write-Error " -> Ghost record detected (ID $id). Delete manually on website."
                continue
            }
            
            $inst = $actualInstances[$id]
            $deleteUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id/instances/$inst"
            
            try {
                Invoke-RestMethod -Uri $deleteUrl -Headers $authHeaders -Method Delete
                Write-Host " -> DELETED ID $id"
            }
            catch {
                Write-Error " -> FAILED to delete ID $id - $_"
            }
            Start-Sleep -Seconds 1.1 # Rate Limit
        }
    }
    else { Write-Host "`n--- No items to delete ---" }

    # --------------------------------------------------------------------------
    # 6. EXECUTE ADDS
    # --------------------------------------------------------------------------
    if ($toAdd.Count -gt 0) {
        Write-Host "`n--- Processing Adds ($($toAdd.Count)) ---"
        foreach ($id in $toAdd) {
            $expected = $desiredArtistMap[$id]
            Write-Host "Processing ID $id..."
            
            $valPass = $true
            
            # --- Validation Step ---
            # If an artist is provided in JSON, check Discogs to ensure it matches.
            if (-not [string]::IsNullOrWhiteSpace($expected)) {
                try {
                    $details = Invoke-RestMethod -Uri "https://api.discogs.com/releases/$id" -Headers $authHeaders -Method Get
                    if ($details.artists_sort -notlike "*$expected*") {
                        Write-Warning " -> VALIDATION FAILED: Artist mismatch ('$($details.artists_sort)' vs '$expected'). Skipping."
                        $valPass = $false
                    }
                }
                catch {
                    Write-Error " -> FAILED to fetch release details for validation. Skipping."
                    $valPass = $false
                }
            }

            # --- Add Step ---
            if ($valPass) {
                $addUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id"
                try {
                    Invoke-RestMethod -Uri $addUrl -Headers $authHeaders -Method Post -Body ""
                    Write-Host " -> ADDED ID $id"
                }
                catch {
                    Write-Error " -> FAILED to add ID $id - $_"
                }
            }
            Start-Sleep -Seconds 1.1 # Rate Limit
        }
    }
    else { Write-Host "`n--- No items to add ---" }

    Write-Host "`nSync Complete!"
}
catch {
    Write-Error "Critical Script Failure: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}