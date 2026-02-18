
# GitHub Automation Script for Trend King EA

Write-Host "👑 Trend King EA - GitHub Setup" -ForegroundColor Cyan
Write-Host "--------------------------------"

# 1. Get API Key
$apiKey = Read-Host "Enter your GitHub Personal Access Token (API Key)" -AsSecureString
$apiKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey))

if ([string]::IsNullOrWhiteSpace($apiKeyPlain)) {
    Write-Error "API Key cannot be empty."
    exit
}

# 2. Configure Headers
$headers = @{
    "Authorization" = "token $apiKeyPlain"
    "Accept"        = "application/vnd.github.v3+json"
}

# 3. Create Repository
Write-Host "`nCreating 'Trend-King-EA' repository..." -ForegroundColor Yellow
$body = @{
    name = "Trend-King-EA"
    description = "Trend King EA - Auto Trading Bot"
    private = $false 
    auto_init = $false
} | ConvertTo-Json

try {
    $response = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body
    $repoUrl = $response.clone_url
    $username = $response.owner.login
    Write-Host "✅ Repository Created: $repoUrl" -ForegroundColor Green
}
catch {
    Write-Error "Failed to create repository. Check your API Key or if repo already exists."
    Write-Host $_.Exception.Message -ForegroundColor Red
    # Continue? Maybe it exists.
}

# 4. Initialize Git
Write-Host "`nInitializing Git..." -ForegroundColor Yellow
git init
git add .
git commit -m "Initial Commit: Trend King EA v2.00"
git branch -M main

# 5. Remote Add & Push
$remoteUrl = "https://$username`:$apiKeyPlain@github.com/$username/Trend-King-EA.git"
git remote remove origin 2>$null
git remote add origin $remoteUrl

Write-Host "`Pushing to GitHub..." -ForegroundColor Yellow
git push -u origin main

if ($?) {
    Write-Host "`n✅ SUCCESS!" -ForegroundColor Green
    $rawUrl = "https://raw.githubusercontent.com/$username/Trend-King-EA/main/accounts.txt"
    Write-Host "YOUR AUTH URL:" -ForegroundColor Cyan
    Write-Host $rawUrl -ForegroundColor White -BackgroundColor Black
    Write-Host "`nCopy this URL into the EA Settings."
}
else {
    Write-Host "`n❌ Push Failed. Check Git installation or credentials." -ForegroundColor Red
}

Read-Host "Press Enter to Exit"
