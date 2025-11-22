<#
.SYNOPSIS
    Synchronizes the local state file with the Discogs API using modular functions.

.DESCRIPTION
    This script serves as the "Engine" for the declarative sync process.
    It uses distinct functions to Load Config, Load State, Fetch Discogs Data, 
    and perform the Sync operations (Add/Delete).

.PARAMETER ConfigFilePath
    Path to the config.json file containing your Discogs Username and Token.

.PARAMETER StateFilePath
    Path to the my_collection.json file containing your desired records.

.PARAMETER FolderId
    The Discogs Folder ID to sync. Defaults to 1 (Uncategorized).

.PARAMETER UserAgent
    The User-Agent string sent to the Discogs API.
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
    [string]$UserAgent = "MyPowerShellCollectionScript/23.0"
)

# ==============================================================================
# 1. HELPER FUNCTIONS
# ==============================================================================

function Get-DiscogsConfig {
    param ([string]$Path)
    Write-Verbose "Loading configuration from $Path"
    
    if (-not (Test-Path $Path)) { throw "Config file not found at $Path" }
    $cfg = Get-Content -Path $Path | ConvertFrom-Json
    
    if ([string]::IsNullOrWhiteSpace($cfg.username) -or [string]::IsNullOrWhiteSpace($cfg.token)) {
        throw "Config file is missing username or token."
    }

    return [PSCustomObject]@{
        Username = $cfg.username
        Headers  = @{ 
            "Authorization" = "Discogs token=$($cfg.token)"; 
            "User-Agent"    = $UserAgent 
        }
    }
}

function Get-LocalState {
    param ([string]$Path)
    Write-Verbose "Loading local state from $Path"

    if (-not (Test-Path $Path)) { throw "State file not found at $Path" }
    $json = Get-Content -Path $Path | ConvertFrom-Json

    # PowerShell Quirk: Force 'records' to be an array @()
    $records = if ($json.records) { @($json.records) } else { @() }

    $ids = @()
    $map = @{}

    foreach ($r in $records) {
        $null = $ids.Add($r.id)
        $map[$r.id] = $r.artist
    }

    return @{
        Ids       = $ids
        ArtistMap = $map
    }
}

function Get-RemoteState {
    param ($Config, $Folder)
    Write-Verbose "Fetching remote state from Discogs..."

    $ids = @()
    $instances = @{} 
    $nextUrl = "https://api.discogs.com/users/$($Config.Username)/collection/folders/$Folder/releases?per_page=100"

    do {
        $resp = Invoke-RestMethod -Uri $nextUrl -Headers $Config.Headers -Method Get
        $releases = @($resp.releases) # Force array

        if ($releases.Count -eq 0) { 
            $nextUrl = $null 
        }
        else {
            foreach ($item in $releases) { 
                $null = $ids.Add($item.id)
                
                # ------------------------------------------------------------------
                # WHY WE NEED THE INSTANCE MAP:
                # ------------------------------------------------------------------
                # Discogs distinguishes between the 'Release ID' (Public Catalog Info)
                # and the 'Instance ID' (Your specific physical copy in your collection).
                #
                # While we use Release ID to ADD items, we MUST use the Instance ID
                # to DELETE items.
                #
                # API DOCS: https://www.discogs.com/developers/#page:user-collection,header:user-collection-delete-instance-from-folder
                # ------------------------------------------------------------------
                if (-not $instances.ContainsKey($item.id)) {
                    $instances[$item.id] = $item.instance_id
                }
            }
            $nextUrl = $resp.pagination.urls.next
        }
    } while ($nextUrl)

    return @{
        Ids       = $ids
        Instances = $instances
    }
}

function Invoke-DiscogsDelete {
    param ($List, $InstanceMap, $Config, $Folder)
    
    foreach ($id in $List) {
        # Check for "Ghost Records" (Items that exist in Release list but have no Instance ID)
        if (-not $InstanceMap.ContainsKey($id)) {
            Write-Error " -> Ghost record detected (ID $id). Delete manually on website."
            continue
        }
        
        # Retrieve the required Instance ID from our map
        $inst = $InstanceMap[$id]
        
        # The Delete Endpoint requires the Instance ID
        $url = "https://api.discogs.com/users/$($Config.Username)/collection/folders/$Folder/releases/$id/instances/$inst"
        
        try {
            Invoke-RestMethod -Uri $url -Headers $Config.Headers -Method Delete
            Write-Host " -> DELETED ID $id" -ForegroundColor Red
        }
        catch {
            Write-Error " -> FAILED to delete ID $id - $_"
        }
        Start-Sleep -Seconds 1.1
    }
}

function Invoke-DiscogsAdd {
    param ($List, $ArtistMap, $Config, $Folder)

    foreach ($id in $List) {
        $expected = $ArtistMap[$id]
        Write-Host "Processing ID $id..." -NoNewline
        
        $canAdd = $true
        
        # Validation Step
        if (-not [string]::IsNullOrWhiteSpace($expected)) {
            try {
                $details = Invoke-RestMethod -Uri "https://api.discogs.com/releases/$id" -Headers $Config.Headers -Method Get
                if ($details.artists_sort -notlike "*$expected*") {
                    Write-Warning "`n -> VALIDATION FAILED: Artist mismatch ('$($details.artists_sort)' vs '$expected')."
                    $canAdd = $false
                }
            }
            catch {
                Write-Error "`n -> FAILED to validate release. Skipping."
                $canAdd = $false
            }
        }

        # Add Step
        if ($canAdd) {
            $url = "https://api.discogs.com/users/$($Config.Username)/collection/folders/$Folder/releases/$id"
            try {
                Invoke-RestMethod -Uri $url -Headers $Config.Headers -Method Post -Body ""
                Write-Host " ADDED" -ForegroundColor Green
            }
            catch {
                Write-Error "`n -> FAILED to add ID $id - $_"
            }
        }
        Start-Sleep -Seconds 1.1
    }
}

# ==============================================================================
# 2. MAIN EXECUTION FLOW
# ==============================================================================

try {
    # Phase 1: Config
    $configData = Get-DiscogsConfig -Path $ConfigFilePath
    Write-Host "Authenticated as $($configData.Username)"

    # Phase 2: Load States
    $local = Get-LocalState -Path $StateFilePath
    Write-Host "Desired State: $($local.Ids.Count) items found in file."

    $remote = Get-RemoteState -Config $configData -Folder $FolderId
    Write-Host "Actual State:  $($remote.Ids.Count) items found on Discogs."

    # Phase 3: Calculate Diffs
    $toAdd = @()
    $toDelete = @()

    if ($local.Ids.Count -gt 0) { 
        $toAdd = @($local.Ids.Where({ -not $remote.Ids.Contains($_) })) 
    }
    if ($remote.Ids.Count -gt 0) { 
        $toDelete = @($remote.Ids.where({ -not $local.Ids.Contains($_) })) 
    }

    # Phase 4: Sync
    if ($toDelete.Count -gt 0) {
        Write-Host "`n--- Processing Deletes ($($toDelete.Count)) ---"
        Invoke-DiscogsDelete -List $toDelete -InstanceMap $remote.Instances -Config $configData -Folder $FolderId
    }
    else { 
        Write-Host "`n--- No items to delete ---" 
    }

    if ($toAdd.Count -gt 0) {
        Write-Host "`n--- Processing Adds ($($toAdd.Count)) ---"
        Invoke-DiscogsAdd -List $toAdd -ArtistMap $local.ArtistMap -Config $configData -Folder $FolderId
    }
    else { 
        Write-Host "`n--- No items to add ---" 
    }

    Write-Host "`nSync Complete!"
}
catch {
    Write-Error "Critical Script Failure: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}