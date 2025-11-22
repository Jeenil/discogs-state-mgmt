[CmdletBinding()]
param ()

# --- Configuration ---
$ConfigFilePath = "$PSScriptRoot\config.json"
$BarcodeFilePath = "$PSScriptRoot\barcodes.json"
$StateFilePath = "$PSScriptRoot\my_collection.json"
$UserAgent = "MyPowerShellCollectionScript/18.0"

# 1. Load Config
if (-not (Test-Path $ConfigFilePath)) { throw "config.json not found." }
$config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
$authHeaders = @{ "Authorization" = "Discogs token=$($config.token)"; "User-Agent" = $UserAgent }

# 2. Load Barcodes
if (-not (Test-Path $BarcodeFilePath)) { throw "barcodes.json not found." }
$barcodes = Get-Content -Path $BarcodeFilePath | ConvertFrom-Json

if ($barcodes.Count -eq 0) { Write-Warning "barcodes.json is empty."; return }
Write-Host "Found $($barcodes.Count) barcodes to process..." -ForegroundColor Cyan

# 3. Load State File (my_collection.json)
if (Test-Path $StateFilePath) {
    $stateData = Get-Content -Path $StateFilePath | ConvertFrom-Json
    # Ensure 'records' is an array (PowerShell quirk with single items)
    if ($stateData.records -isnot [Array]) { $stateData.records = @($stateData.records) }
    $existingIds = $stateData.records.id
}
else {
    $stateData = [PSCustomObject]@{ records = @() }
    $existingIds = @()
}

# 4. Process Barcodes
foreach ($code in $barcodes) {
    Write-Host "`nSearching for $code..."
    
    try {
        $url = "https://api.discogs.com/database/search?type=release&barcode=$code"
        $response = Invoke-RestMethod -Uri $url -Headers $authHeaders -Method Get
    }
    catch {
        Write-Error "Failed to search for $code"
        continue
    }

    if ($response.results.Count -eq 0) {
        Write-Warning " -> No results found for $code"
        continue
    }

    # Grab the first result (Best Guess)
    $match = $response.results[0]

    # Check for duplicates in your existing collection
    if ($existingIds -contains $match.id) {
        Write-Warning " -> Skipped: ID $($match.id) is already in my_collection.json"
        continue
    }

    # Split Title/Artist
    if ($match.title -match " - ") {
        $artist = $match.title.Split(' - ')[0]
        $title = $match.title.Split(' - ')[1]
    }
    else {
        $artist = $match.title
        $title = ""
    }

    # Add to State Data
    $newRecord = [PSCustomObject]@{
        id     = $match.id
        artist = $artist
        notes  = "$title (Barcode: $code)"
    }
    
    $stateData.records += $newRecord
    $existingIds += $match.id # Update local check list
    
    Write-Host " -> [ADDED] $($match.title) (ID: $($match.id))" -ForegroundColor Green
    
    # Rate limit
    Start-Sleep -Seconds 1.1
}

# 5. Save State File
$stateData | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFilePath -Encoding utf8
Write-Host "`nSuccess! my_collection.json updated." -ForegroundColor Cyan