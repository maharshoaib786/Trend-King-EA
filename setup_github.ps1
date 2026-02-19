# GitHub Automation Script for Trend King EA

param([string]$ApiKey = "")

Write-Host "👑 Trend King EA - GitHub Setup" -ForegroundColor Cyan
Write-Host "--------------------------------"

# 1. Get API Key

$apiKeyPlain = $ApiKey

if ([string]::IsNullOrWhiteSpace($apiKeyPlain)) {
    $apiKeySecure = Read-Host "Enter your GitHub Personal Access Token (API Key)" -AsSecureString
    $apiKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKeySecure))
}

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
    name        = "Trend-King-EA"
    description = "Trend King EA - Auto Trading Bot"
    private     = $false 
    auto_init   = $false
} | ConvertTo-Json

try {
    # Try to GET user info first to ensure API key works and get username
    $userResponse = Invoke-RestMethod -Uri "https://api.github.com/user" -Method Get -Headers $headers
    $username = $userResponse.login
    Write-Host "✅ Authenticated as: $username" -ForegroundColor Green

    # Check if repo already exists
    try {
        $checkRepo = Invoke-RestMethod -Uri "https://api.github.com/repos/$username/Trend-King-EA" -Method Get -Headers $headers -ErrorAction Stop
        Write-Host "⚠️ Repository 'Trend-King-EA' already exists. Proceeding with push..." -ForegroundColor Yellow
        $repoUrl = $checkRepo.html_url # HTML URL for logging, clone_url for git
    }
    catch {
        # Assuming failure means Doesn't Exist (404), create it
        Write-Host "Creating 'Trend-King-EA' repository..." -ForegroundColor Yellow
        $response = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body
        $repoUrl = $response.clone_url
        Write-Host "✅ Repository Created: $repoUrl" -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed during GitHub API operations."
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit
}

# 4. Initialize Git
Write-Host "`nInitializing Git..." -ForegroundColor Yellow
git init
git add .
git commit -m "Update Trend King EA v2.00"
git branch -M main

# 5. Remote Add & Push
# Construct URL with Auth Token
$authRemoteUrl = "https://${username}:${apiKeyPlain}@github.com/${username}/Trend-King-EA.git"

git remote remove origin 2>$null
git remote add origin $authRemoteUrl

Write-Host "Pushing to GitHub (Forcing)..." -ForegroundColor Yellow
git push -u origin main --force

if ($?) {
    Write-Host "`n✅ SUCCESS!" -ForegroundColor Green
    $rawUrl = "https://raw.githubusercontent.com/maharshoaib786/Trend-King-EA/refs/heads/main/accounts.txt"
    Write-Host "YOUR AUTH URL:" -ForegroundColor Cyan
    Write-Host $rawUrl -ForegroundColor White -BackgroundColor Black
    Write-Host "`nCopy this URL into the EA Settings."
}
else {
    Write-Host "`n❌ Push Failed. Check Git installation or credentials." -ForegroundColor Red
}

Read-Host "Press Enter to Exit"
