# Optimized OTA Update Script for Trend King EA

param([string]$CommitMessage = "Auto Update")

Write-Host "👑 Trend King EA - Publishing Update..." -ForegroundColor Cyan
Write-Host "---------------------------------------"

# 1. Config
$eaFile = "d:\WorkSpace\Trend_King_Repo\Trend_King_EA.mq5"
$ex5File = "d:\WorkSpace\Trend_King_Repo\Trend_King_EA.ex5"
$jsonFile = "d:\WorkSpace\Trend_King_Repo\version.json"
$apiFile = "d:\WorkSpace\Trend_King_Repo\API.txt"
$compiler = "C:\Program Files\MetaTrader 5\metaeditor64.exe" 
$logFile = "d:\WorkSpace\Trend_King_Repo\compile_log.txt"

# 2. Get API Key from File
if (Test-Path $apiFile) {
    $apiKey = Get-Content $apiFile -Raw
    $apiKey = $apiKey.Trim()
}
else {
    Write-Error "API.txt not found!"
    exit
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Error "API Key is empty in API.txt"
    exit
}

# 3. Read Version from Source
$content = Get-Content $eaFile
$versionLine = $content | Select-String -Pattern '#property version\s+"([0-9.]+)"'
if ($versionLine.Matches.Count -gt 0) {
    $version = $versionLine.Matches[0].Groups[1].Value
    Write-Host "Current Version defined in code: $version" -ForegroundColor Green
}
else {
    Write-Error "Could not find #property version in .mq5 file"
    exit
}

# 4. Compile EA
Write-Host "Compiling EA..." -ForegroundColor Yellow
if (Test-Path $logFile) { Remove-Item $logFile }

$proc = Start-Process -FilePath $compiler -ArgumentList "/compile:`"$eaFile`"", "/log:`"$logFile`"" -PassThru -Wait

if (Test-Path $logFile) {
    $logContent = Get-Content $logFile
    if ($logContent -match "0 errors") {
        Write-Host "✅ Compilation Successful!" -ForegroundColor Green
    }
    else {
        Write-Error "❌ Compilation Failed. Check log."
        $logContent | Write-Host
        exit
    }
}
else {
    Write-Error "Compilation log not found."
    exit
}

# 5. Update version.json
$jsonContent = @{
    version = $version
    updated = (Get-Date).ToString("yyyy-MM-dd")
    url     = "https://raw.githubusercontent.com/maharshoaib786/Trend-King-EA/main/Trend_King_EA.ex5"
} | ConvertTo-Json -Depth 2

Set-Content -Path $jsonFile -Value $jsonContent
Write-Host "Updated version.json to v$version" -ForegroundColor Green

# 6. Push to GitHub
Write-Host "Pushing to GitHub..." -ForegroundColor Yellow

# Configure remote with token (securely)
git remote remove origin 2>$null
$authUrl = "https://maharshoaib786:${apiKey}@github.com/maharshoaib786/Trend-King-EA.git"
git remote add origin $authUrl

git add .
git commit -m "v${version}: $CommitMessage"
git push origin main --force

if ($?) {
    Write-Host "`n🚀 DEPLOYMENT COMPLETE!" -ForegroundColor Green
    Write-Host "New version v$version is live on GitHub."
}
else {
    Write-Error "Git Push Failed."
}
