[CmdletBinding()]
param ()

# --- Configuration ---
$ConfigFilePath = "$PSScriptRoot\config.json"
$StateFilePath = "$PSScriptRoot\my_collection.json"
$FolderId = 1 # 1 = "Uncategorized" folder
$UserAgent = "MyPowerShellCollectionScript/14.0"

# --- Main Script ---
try {
    Write-Host "`n=== Discogs Collection Sync ===" -ForegroundColor Cyan
    
    # 1. Load Config
    Write-Host "`n[1/6] Loading configuration..." -ForegroundColor Yellow
    if (-not (Test-Path $ConfigFilePath)) { 
        throw "config.json not found at $ConfigFilePath" 
    }
    
    $config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    
    if ([string]::IsNullOrWhiteSpace($config.username) -or [string]::IsNullOrWhiteSpace($config.token)) {
        throw "Config file is missing username or token."
    }
    
    $authHeaders = @{
        "Authorization" = "Discogs token=$($config.token)"
        "User-Agent"    = $UserAgent
    }
    
    Write-Host "  ✓ Authenticated as: $($config.username)" -ForegroundColor Green

    # 2. Load Desired State
    Write-Host "`n[2/6] Loading desired state..." -ForegroundColor Yellow
    if (-not (Test-Path $StateFilePath)) { 
        throw "my_collection.json not found at $StateFilePath" 
    }
    
    $desiredState = Get-Content -Path $StateFilePath | ConvertFrom-Json
    
    # Build maps
    $desiredIds = [System.Collections.Generic.HashSet[int]]@()
    $desiredArtistMap = @{}

    if ($desiredState.records) {
        foreach ($record in $desiredState.records) {
            # Cast to [int] for consistency
            $recordId = [int]$record.id
            $null = $desiredIds.Add($recordId)
            if ($record.artist) {
                $desiredArtistMap[$recordId] = $record.artist
            }
        }
    }
    
    Write-Host "  ✓ Desired state: $($desiredIds.Count) record(s)" -ForegroundColor Green

    # 3. Load Actual State from Discogs
    Write-Host "`n[3/6] Fetching current collection from Discogs..." -ForegroundColor Yellow
    $actualIds = [System.Collections.Generic.HashSet[int]]@()
    $actualInstances = @{} # Maps: release_id -> instance_id
    $page = 1
    $nextUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases?per_page=100"

    do {
        Write-Host "  Fetching page $page..." -NoNewline
        
        try {
            $response = Invoke-RestMethod -Uri $nextUrl -Headers $authHeaders -Method Get
            
            # Handle empty collection
            if (-not $response.releases -or $response.releases.Count -eq 0) {
                Write-Host " (empty)" -ForegroundColor Gray
                break
            }
            
            # Force array with @() wrapper and process each item
            $releases = @($response.releases)
            Write-Host " $($releases.Count) item(s)" -ForegroundColor Gray
            
            foreach ($item in $releases) {
                # Cast to [int] to ensure consistent types
                $releaseId = [int]$item.id
                $instanceId = [int]$item.instance_id
                
                # Add to tracking
                $null = $actualIds.Add($releaseId)
                
                # Store instance_id (use first one if duplicates exist)
                if (-not $actualInstances.ContainsKey($releaseId)) {
                    $actualInstances[$releaseId] = $instanceId
                    Write-Verbose "  Stored: Release $releaseId -> Instance $instanceId"
                }
            }
            
            # Get next page URL
            $nextUrl = $response.pagination.urls.next
            $page++
            
        }
        catch {
            Write-Host " FAILED" -ForegroundColor Red
            throw "Failed to fetch collection: $_"
        }
        
        Start-Sleep -Milliseconds 100 # Small delay between pages
        
    } while ($nextUrl)
    
    Write-Host "  ✓ Actual state: $($actualIds.Count) record(s)" -ForegroundColor Green

    # 4. Calculate Differences
    Write-Host "`n[4/6] Calculating differences..." -ForegroundColor Yellow
    
    $toAdd = @()
    if ($desiredIds.Count -gt 0) {
        $toAdd = @($desiredIds.Where({ -not $actualIds.Contains($_) }))
    }
    
    $toDelete = @()
    if ($actualIds.Count -gt 0) {
        $toDelete = @($actualIds.Where({ -not $desiredIds.Contains($_) }))
    }
    
    Write-Host "  ✓ To add: $($toAdd.Count)" -ForegroundColor $(if ($toAdd.Count -gt 0) { "Cyan" } else { "Gray" })
    Write-Host "  ✓ To delete: $($toDelete.Count)" -ForegroundColor $(if ($toDelete.Count -gt 0) { "Cyan" } else { "Gray" })

    # 5. Execute Deletes
    Write-Host "`n[5/6] Processing deletes..." -ForegroundColor Yellow
    
    if ($toDelete.Count -gt 0) {
        foreach ($id in $toDelete) {
            Write-Host "  Deleting Release $id..." -NoNewline
            
            # Cast to [int] for hashtable lookup
            $lookupId = [int]$id
            
            # Check if we have instance_id
            if (-not $actualInstances.ContainsKey($lookupId)) {
                Write-Host " FAILED (no instance_id)" -ForegroundColor Red
                Write-Warning "    Cannot find instance_id for Release $id. This shouldn't happen."
                Write-Warning "    Try deleting manually at: https://www.discogs.com/release/$id"
                continue
            }
            
            $instanceId = $actualInstances[$lookupId]
            $deleteUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id/instances/$instanceId"
            
            try {
                Invoke-RestMethod -Uri $deleteUrl -Headers $authHeaders -Method Delete
                Write-Host " SUCCESS" -ForegroundColor Green
            }
            catch {
                Write-Host " FAILED" -ForegroundColor Red
                Write-Error "    Error: $_"
            }
            
            Start-Sleep -Seconds 1.1 # Rate limit
        }
    }
    else {
        Write-Host "  (nothing to delete)" -ForegroundColor Gray
    }

    # 6. Execute Adds
    Write-Host "`n[6/6] Processing adds..." -ForegroundColor Yellow
    
    if ($toAdd.Count -gt 0) {
        foreach ($id in $toAdd) {
            # Cast for hashtable lookup
            $lookupId = [int]$id
            $expectedArtist = $desiredArtistMap[$lookupId]
            Write-Host "  Adding Release $id..." -NoNewline
            
            # Validate artist if specified
            $validationPassed = $true
            if (-not [string]::IsNullOrWhiteSpace($expectedArtist)) {
                try {
                    $releaseUrl = "https://api.discogs.com/releases/$id"
                    $releaseDetails = Invoke-RestMethod -Uri $releaseUrl -Headers $authHeaders -Method Get
                    $actualArtist = $releaseDetails.artists_sort
                    
                    if ($actualArtist -notlike "*$expectedArtist*") {
                        Write-Host " VALIDATION FAILED" -ForegroundColor Red
                        Write-Warning "    Expected artist: '$expectedArtist'"
                        Write-Warning "    Actual artist: '$actualArtist'"
                        $validationPassed = $false
                    }
                    
                    Start-Sleep -Seconds 1.1 # Rate limit for validation call
                }
                catch {
                    Write-Host " VALIDATION ERROR" -ForegroundColor Red
                    Write-Error "    Failed to validate: $_"
                    $validationPassed = $false
                }
            }
            
            # Add to collection if validation passed
            if ($validationPassed) {
                try {
                    $addUrl = "https://api.discogs.com/users/$($config.username)/collection/folders/$FolderId/releases/$id"
                    Invoke-RestMethod -Uri $addUrl -Headers $authHeaders -Method Post -Body ""
                    Write-Host " SUCCESS" -ForegroundColor Green
                }
                catch {
                    Write-Host " FAILED" -ForegroundColor Red
                    Write-Error "    Error: $_"
                }
            }
            
            Start-Sleep -Seconds 1.1 # Rate limit
        }
    }
    else {
        Write-Host "  (nothing to add)" -ForegroundColor Gray
    }

    Write-Host "`n✓ Sync complete!`n" -ForegroundColor Green

}
catch {
    Write-Host "`n✗ Critical Error: $_`n" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}