<#
.SYNOPSIS
    Safely adds new barcodes to your collection file.

.DESCRIPTION
    1. Reads barcodes.json.
    2. Searches Discogs for each one.
    3. Checks if that record is ALREADY in my_collection.json.
    4. If it is new, it appends it.
    5. It NEVER deletes anything.

.EXAMPLE
    .\Import-Barcodes.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigFilePath = "$PSScriptRoot\config.json",

    [Parameter(Mandatory = $false)]
    [string]$BarcodeFilePath = "$PSScriptRoot\barcodes.json",

    [Parameter(Mandatory = $false)]
    [string]$StateFilePath = "$PSScriptRoot\my_collection.json"
)

# --- Configuration ---
$UserAgent = "MyPowerShellCollectionScript/21.0"

# 1. Load Config
if (-not (Test-Path $ConfigFilePath)) { throw "Config file not found." }
$config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
$authHeaders = @{ 
    "Authorization" = "Discogs token=$($config.token)"
    "User-Agent"    = $UserAgent 
}

# 2. Load Barcodes
if (-not (Test-Path $BarcodeFilePath)) { throw "barcodes.json not found." }
$barcodes = Get-Content -Path $BarcodeFilePath | ConvertFrom-Json

# 3. Load EXISTING State File
# We load the current file so we don't overwrite it!
if (Test-Path $StateFilePath) {
    $stateJson = Get-Content -Path $StateFilePath | ConvertFrom-Json
    # Force 'records' to be an array even if it has only 1 item
    if ($stateJson.records) { 
        $currentRecords = @($stateJson.records)
    }
    else {
        $currentRecords = @()
    }
}
else {
    $currentRecords = @()
}

# Create a list of IDs we already have (to check for duplicates)
$existingIds = $currentRecords.id

Write-Host "Processing $($barcodes.Count) barcodes..." -ForegroundColor Cyan

# 4. Process Each Barcode
foreach ($code in $barcodes) {
    Write-Host "Searching for $code..." -NoNewline
    
    try {
        $url = "https://api.discogs.com/database/search?type=release&barcode=$code"
        $response = Invoke-RestMethod -Uri $url -Headers $authHeaders -Method Get
    }
    catch {
        Write-Error "`nFailed to search for $code"
        continue
    }

    if ($response.results.Count -eq 0) {
        Write-Warning "`n -> No results found for $code"
        continue
    }

    # Best Guess: Take the first result
    $match = $response.results[0]

    # --- DUPLICATE CHECK ---
    # If we already have this ID, skip it.
    if ($existingIds -contains $match.id) {
        Write-Warning " Found: $($match.title) (Skipped - Already in collection)"
        continue
    }

    Write-Host " Found: $($match.title) (NEW!)" -ForegroundColor Green

    # Split "Artist - Title"
    if ($match.title -match " - ") {
        $artist = $match.title.Split(' - ')[0]
        $title = $match.title.Split(' - ')[1]
    }
    else {
        $artist = $match.title
        $title = ""
    }

    # Add to our list
    $currentRecords += [PSCustomObject]@{
        id     = $match.id
        artist = $artist
        notes  = "$title (Barcode: $code)"
    }
    
    # Update our check list so we don't add the same one twice in this run
    $existingIds += $match.id

    Start-Sleep -Seconds 1.1 
}

# 5. Save Updated File
$newState = [PSCustomObject]@{ records = $currentRecords }
$newState | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFilePath -Encoding utf8

Write-Host "`n------------------------------------------------"
Write-Host "Success! Added new items to $StateFilePath"
Write-Host "Total Records: $($currentRecords.Count)"
Write-Host "Run 'Sync-Collection.ps1' to push to Discogs." -ForegroundColor Yellow