#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$source = 'https://raw.githubusercontent.com/zorgiy/YandexDiskBackup/main/YandexDiskBackup.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\YandexDiskBackup'
$file = Join-Path $installDir 'YandexDiskBackup.ps1'
Write-Host 'Установка YandexDiskBackup' -ForegroundColor Cyan
Write-Host "Источник: $source"
Write-Host "Папка программы: $installDir"
Write-Host 'Резервные копии и сохранённые ключи не удаляются.'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$temp = "$file.new"
try {
    Invoke-WebRequest -Uri $source -OutFile $temp -TimeoutSec 45
    if ((Get-Item -LiteralPath $temp).Length -lt 1000) { throw 'Получен слишком маленький файл.' }
    $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    Write-Host "SHA256 загруженного скрипта: $hash"
    Move-Item -LiteralPath $temp -Destination $file -Force
    Write-Host 'Запускаю актуальную версию...' -ForegroundColor Green
    & (Get-Process -Id $PID).Path -NoProfile -File $file
} catch {
    Write-Host "ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
