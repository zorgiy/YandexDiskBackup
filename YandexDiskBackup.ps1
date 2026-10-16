#requires -Version 7.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$homeDir=Join-Path $env:LOCALAPPDATA 'YandexDiskBackup'
New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
$config=Join-Path $homeDir 'folder.txt'
$secrets=Join-Path $homeDir 'credentials.xml'
function Msg($m,$c='Gray'){Write-Host $m -ForegroundColor $c}
function Api($path,$offset){
 $url='https://cloud-api.yandex.net/v1/disk/resources?path='+[uri]::EscapeDataString($path)+'&limit=200&offset='+$offset
 Invoke-RestMethod -Uri $url -Headers @{Authorization='OAuth '+$script:token} -TimeoutSec 20
}
function SafeName($n) {
 $s=([string]$n -replace '[<>:"/\\|?*\x00-\x1f]','_').TrimEnd(' ','.')
 if($s){return $s};return '_unnamed'
}
function Download($remote,$target,[long]$size){
 $url='https://webdav.yandex.ru/'+((($remote -replace '^disk:/','').Split('/') | ForEach-Object {[uri]::EscapeDataString($_)}) -join '/')
 $seconds=if($size -ge 20MB){120}else{10}
 $cts=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($seconds))
 $tmp=$target+'.partial';$res=$null;$stream=$null;$dest=$null
 try{
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  $res=$script:http.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
  if(-not $res.IsSuccessStatusCode){return 'HTTP '+[int]$res.StatusCode}
  $stream=$res.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
  $dest=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $stream.CopyToAsync($dest,$cts.Token).GetAwaiter().GetResult()
  $dest.Dispose();$dest=$null
  if((Get-Item -LiteralPath $tmp).Length -ne $size){return 'SIZE_MISMATCH'}
  if(Test-Path -LiteralPath $target){return 'EXISTS'}
  [IO.File]::Move($tmp,$target);return 'OK'
 }catch{
  if($cts.IsCancellationRequested){return 'TIMEOUT '+$seconds+'s'}
  return 'ERROR '+$_.Exception.GetBaseException().Message
 }finally{
  if($dest){$dest.Dispose()};if($stream){$stream.Dispose()};if($res){$res.Dispose()}
  $cts.Dispose();Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
 }
}
function Walk($remote,$folder){
 New-Item -ItemType Directory -Path $folder -Force | Out-Null
 Msg ('ПАПКА: '+$remote) 'Cyan'
 $offset=0
 do{
  $reply=Api $remote $offset
  $items=@($reply._embedded.items | Where-Object {$null -ne $_})
  foreach($item in $items){
   $target=Join-Path $folder (SafeName $item.name)
   if($item.type -eq 'dir'){Walk ([string]$item.path) $target;continue}
   if($item.type -ne 'file'){continue}
   $script:count.Total++
   $size=[long]$item.size
   if(Test-Path -LiteralPath $target){
    if((Get-Item -LiteralPath $target).Length -eq $size){$script:count.Existing++;continue}
    $script:count.Conflicts++;Msg ('НЕ ПЕРЕЗАПИСАН, отличается размер: '+$target) 'Yellow';continue
   }
   Msg ('СКАЧИВАЕМ: '+$item.path)
   $status=Download ([string]$item.path) $target $size
   if($status -eq 'OK'){$script:count.Downloaded++;Msg '  УСПЕШНО: скачан оригинал' 'Green'}
   else{
    $script:count.Failed++
    $why=switch -Regex ($status){
     '^HTTP 503' {' (сервер временно не отдаёт файл)';break}
     '^HTTP 500' {' (внутренняя ошибка сервера)';break}
     '^HTTP 403' {' (доступ запрещён)';break}
     '^TIMEOUT' {' (истекло время ожидания)';break}
     default {''}
    }
    Msg ('  НЕ СКАЧАН: '+$status+$why) 'Yellow'
   }
   $row=@((Get-Date -Format o),$status,[string]$item.path,[string]$size) -join [char]9
   Add-Content -LiteralPath $script:log -Value $row -Encoding utf8
  }
  $offset+=$items.Count
 }while($items.Count -gt 0 -and $offset -lt [int]$reply._embedded.total)
}
function Auth {
 if(Test-Path -LiteralPath $secrets){
  try{
   $x=Import-Clixml -LiteralPath $secrets
   return @{Login=$x.Dav.UserName;Password=$x.Dav.GetNetworkCredential().Password;Token=$x.Oauth.GetNetworkCredential().Password}
  }catch{Msg 'Нужно повторно ввести ключи.' 'Yellow'}
 }
 $login=Read-Host 'Логин Яндекса'
 $pass=Read-Host 'Пароль приложения WebDAV' -AsSecureString
 $token=Read-Host 'OAuth-токен (disk:read)' -AsSecureString
 if(-not $login){throw 'Пустой логин'}
 if((Read-Host 'Сохранить ключи зашифрованными средствами Windows? (д/н)') -eq 'д'){
  @{Dav=[pscredential]::new($login,$pass);Oauth=[pscredential]::new('OAuth',$token)} | Export-Clixml -LiteralPath $secrets
 }
 return @{Login=$login;Password=[Net.NetworkCredential]::new('',$pass).Password;Token=[Net.NetworkCredential]::new('',$token).Password}
}
while($true){
 Msg '============ YandexDiskBackup ============' 'Cyan'
 Msg '1 — Скачать весь Диск / продолжить недостающие файлы'
 Msg '2 — Где получить ключи'
 Msg '3 — Удалить сохранённые ключи'
 Msg '0 — Выход'
 $option=Read-Host 'Выбор [Enter = 1]'
 if($option -eq '0'){break}
 if($option -eq '2'){
  Msg 'Логин: имя учётной записи Яндекса.'
  Msg 'Пароль WebDAV: https://id.yandex.ru/security/app-passwords'
  Msg 'OAuth: https://oauth.yandex.ru/ — приложение с разрешением disk:read.'
  Msg 'Инструкция: https://yandex.ru/dev/id/doc/ru/tokens/debug-token'
  Read-Host 'Enter для продолжения' | Out-Null;continue
 }
 if($option -eq '3'){Remove-Item -LiteralPath $secrets -Force -ErrorAction SilentlyContinue;continue}
 if($option -and $option -ne '1'){continue}
 $script:http=$null
 try{
  $default=if(Test-Path -LiteralPath $config){(Get-Content -LiteralPath $config -Raw).Trim()}else{Join-Path $PSScriptRoot 'YandexDiskBackup'}
  $entered=Read-Host ('Папка для резервной копии [Enter = '+$default+']')
  $folder=if($entered.Trim()){[Environment]::ExpandEnvironmentVariables($entered.Trim('" '))}else{$default}
  $folder=[IO.Path]::GetFullPath($folder)
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  Set-Content -LiteralPath $config -Value $folder -Encoding utf8
  $creds=Auth;$script:token=$creds.Token
  $handler=[Net.Http.HttpClientHandler]::new()
  $handler.Credentials=[Net.NetworkCredential]::new($creds.Login,$creds.Password)
  $handler.PreAuthenticate=$true
  $script:http=[Net.Http.HttpClient]::new($handler)
  $script:count=[ordered]@{Total=0;Existing=0;Downloaded=0;Failed=0;Conflicts=0}
  $script:log=Join-Path $folder '_backup-status.tsv'
  if(-not(Test-Path -LiteralPath $script:log)){Set-Content -LiteralPath $script:log -Value (@('Time','Result','RemotePath','Bytes') -join [char]9) -Encoding utf8}
  Walk 'disk:/' $folder
  Msg 'ИТОГИ:' 'Cyan'
  foreach($key in $script:count.Keys){Msg ($key+': '+$script:count[$key])}
  Msg ('Резервная копия: '+$folder) 'Green'
 }catch{Msg ('ОШИБКА: '+$_.Exception.Message) 'Red'}
 finally{if($script:http){$script:http.Dispose()};Remove-Variable token -Scope Script -ErrorAction SilentlyContinue}
 Read-Host 'Enter для меню' | Out-Null
}
