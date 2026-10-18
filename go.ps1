$ErrorActionPreference = 'Stop'
$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$uri = "https://raw.githubusercontent.com/zorgiy/YandexDiskBackup/main/install.ps1?v=$stamp"
Invoke-RestMethod -Uri $uri | Invoke-Expression
