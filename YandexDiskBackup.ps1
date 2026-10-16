#requires -Version 7.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$homeDir=Join-Path $env:LOCALAPPDATA 'YandexDiskBackup'
New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
$config=Join-Path $homeDir 'folder.txt'
$secrets=Join-Path $homeDir 'credentials.xml'
function Msg($m,$c='Gray'){Write-Host $m -ForegroundColor $c}

function Pretty-Error([string]$status){
 if($status -match '503'){return "$status (сервер временно недоступен для этого файла)"}
 if($status -match '500'){return "$status (внутренняя ошибка сервера)"}
 if($status -match '403'){return "$status (сервер запрещает доступ)"}
 if($status -match '401'){return "$status (ошибка авторизации)"}
 if($status -match 'TIMEOUT'){return "$status (превышено время ожидания)"}
 if($status -match 'ResponseEnded'){return "$status (соединение оборвалось раньше времени)"}
 if($status -match 'SIZE_MISMATCH'){return "$status (размер не совпал; неполный файл удалён)"}
 return $status
}
function Show-ProgressLine([int]$remainingInFolder){
 $processed=$script:count.Total
 $downloaded=$script:count.Downloaded
 $already=$script:count.Existing
 $failed=$script:count.Failed
 $pending=[Math]::Max(0,$remainingInFolder)
 Msg ("  ПРОГРЕСС: обработано {0} | скачано {1} | уже было {2} | ошибок {3} | осталось в папке {4}" -f $processed,$downloaded,$already,$failed,$pending) 'DarkCyan'
}

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

function Download-Api($remote,$target,[long]$size) {
 try{
  $url='https://cloud-api.yandex.net/v1/disk/resources/download?path='+[uri]::EscapeDataString($remote)
  $result=Invoke-RestMethod -Uri $url -Headers @{Authorization='OAuth '+$script:token} -TimeoutSec 10
  if(-not $result.href){return 'API_NO_LINK'}
  $temp=$target+'.api-partial'
  $timeout=if($size -ge 20MB){120}else{10}
  try{
   Invoke-WebRequest -Uri ([string]$result.href) -OutFile $temp -TimeoutSec $timeout
   if((Get-Item -LiteralPath $temp).Length -ne $size){return 'SIZE_MISMATCH'}
   if(Test-Path -LiteralPath $target){return 'EXISTS'}
   [IO.File]::Move($temp,$target);return 'OK'
  }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
 }catch {
  $httpCode=if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{0}
  if($httpCode){return "HTTP $httpCode"}
  return 'API_ERROR '+$_.Exception.GetBaseException().Message
 }
}
function Get-File($remote,$target,[long]$size) {
 if($script:mode -eq 'WebDAV'){return Download $remote $target $size}
 $result=Download-Api $remote $target $size
 if($result -eq 'OK' -or $script:mode -eq 'API'){return $result}
 if(-not $script:davReady){
  if(-not (Ensure-Dav)){return $result}
 }
 $davResult=Download $remote $target $size
 if($davResult -eq 'OK'){return 'OK'}
 return "$result; WEBDAV=$davResult"
}
function Walk-Dav($url,$local) {
 New-Item -ItemType Directory -Path $local -Force | Out-Null
 Msg ("ПАПКА WebDAV: "+[uri]::UnescapeDataString(([uri]$url).AbsolutePath)) 'Cyan'
 $request=$null;$response=$null
 try{
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new('PROPFIND'),$url)
  $null=$request.Headers.TryAddWithoutValidation('Depth','1')
  $response=$script:http.SendAsync($request).GetAwaiter().GetResult()
  if([int]$response.StatusCode -ne 207){throw "WebDAV: HTTP $([int]$response.StatusCode)"}
  $xmlText=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  [xml]$doc=$xmlText
  $ns=[Xml.XmlNamespaceManager]::new($doc.NameTable)
  $ns.AddNamespace('d','DAV:')
  $nodes=$doc.SelectNodes('//d:response',$ns)
  $selfPath=([uri]$url).AbsolutePath.TrimEnd('/')
  $fileNodes=@($nodes | Where-Object { $_.SelectSingleNode('.//d:getcontentlength',$ns) -ne $null })
  $remainingHere=$fileNodes.Count
  foreach($node in $nodes){
   $href=$node.SelectSingleNode('d:href',$ns)
   if(-not $href){continue}
   $uri=[uri]::new([uri]$url,[string]$href.InnerText)
   if($uri.AbsolutePath.TrimEnd('/') -eq $selfPath){continue}
   $filename=[uri]::UnescapeDataString($uri.AbsolutePath.TrimEnd('/').Split('/')[-1])
   $filename=SafeName $filename
   $target=Join-Path $local $filename
   $isDir=$null -ne $node.SelectSingleNode('.//d:resourcetype/d:collection',$ns)
   if($isDir){Walk-Dav $uri.AbsoluteUri $target;continue}
   $sizeNode=$node.SelectSingleNode('.//d:getcontentlength',$ns)
   if(-not $sizeNode){Msg "Пропуск: нет размера у $filename" 'Yellow';continue}
   $remainingHere--
   $size=[long]$sizeNode.InnerText
   $script:count.Total++
   if(Test-Path -LiteralPath $target){
    if((Get-Item -LiteralPath $target).Length -eq $size){$script:count.Existing++;Show-ProgressLine $remainingHere;continue}
    $script:count.Conflicts++;Msg "Размер отличается, не перезаписано: $target" 'Yellow';Show-ProgressLine $remainingHere;continue
   }
   Msg "СКАЧИВАЕМ: $filename"
   $remotePath='disk:'+([uri]::UnescapeDataString($uri.AbsolutePath))
   $status=Download $remotePath $target $size
   if($status -eq 'OK'){$script:count.Downloaded++;Msg '  УСПЕШНО: скачан оригинал' 'Green'}
   else{$script:count.Failed++;Msg ("  НЕ СКАЧАН: "+(Pretty-Error $status)) 'Yellow'}
   Show-ProgressLine $remainingHere
   Add-Content -LiteralPath $script:log -Value (@((Get-Date -Format o),$status,$uri.AbsoluteUri,$size) -join [char]9) -Encoding utf8
  }
 }finally{if($request){$request.Dispose()};if($response){$response.Dispose()}}
}
function Walk($remote,$folder){
 New-Item -ItemType Directory -Path $folder -Force | Out-Null
 Msg ('ПАПКА: '+$remote) 'Cyan'
 $offset=0
 do{
  $reply=Api $remote $offset
  $items=@($reply._embedded.items | Where-Object {$null -ne $_})
  $remainingHere=@($items | Where-Object {$_.type -eq 'file'}).Count
  foreach($item in $items){
   $target=Join-Path $folder (SafeName $item.name)
   if($item.type -eq 'dir'){Walk ([string]$item.path) $target;continue}
   if($item.type -ne 'file'){continue}
   $script:count.Total++
   $remainingHere--
   $size=[long]$item.size
   if(Test-Path -LiteralPath $target){
    if((Get-Item -LiteralPath $target).Length -eq $size){$script:count.Existing++;Show-ProgressLine $remainingHere;continue}
    $script:count.Conflicts++;Msg ('НЕ ПЕРЕЗАПИСАН, отличается размер: '+$target) 'Yellow';Show-ProgressLine $remainingHere;continue
   }
   Msg ('СКАЧИВАЕМ: '+$item.path)
   $status=Get-File ([string]$item.path) $target $size
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
    Msg ('  НЕ СКАЧАН: '+(Pretty-Error $status)) 'Yellow'
   }
   Show-ProgressLine $remainingHere
   $row=@((Get-Date -Format o),$status,[string]$item.path,[string]$size) -join [char]9
   Add-Content -LiteralPath $script:log -Value $row -Encoding utf8
  }
  $offset+=$items.Count
 }while($items.Count -gt 0 -and $offset -lt [int]$reply._embedded.total)
}

function New-Auth($mode) {
 $creds=@{Login='';Password='';Token='';Saved=$false}
 if($mode -ne 'WebDAV'){
  $creds.Token=[Net.NetworkCredential]::new('',(Read-Host 'OAuth-токен Яндекс Диска (disk:read)' -AsSecureString)).Password.Trim()
 }
 if($mode -eq 'WebDAV'){
  $creds.Login=(Read-Host 'Логин Яндекса БЕЗ @yandex.ru').Trim()
  if($creds.Login -match '@'){$creds.Login=($creds.Login -split '@')[0]}
  $creds.Password=[Net.NetworkCredential]::new('',(Read-Host 'Пароль приложения WebDAV' -AsSecureString)).Password
 }
 return $creds
}
function Auth($mode) {
 if(Test-Path -LiteralPath $secrets){
  try {
   $x=Import-Clixml -LiteralPath $secrets
   $login='';$password='';$token=''
   if($x.Dav){$login=$x.Dav.UserName;$password=$x.Dav.GetNetworkCredential().Password}
   if($x.Oauth){$token=$x.Oauth.GetNetworkCredential().Password}
   return @{Login=$login;Password=$password;Token=$token;Saved=$true}
  }catch{Msg 'Старые сохранённые данные повреждены или недоступны.' 'Yellow'}
 }
 return New-Auth $mode
}
function Check-Api($token){
 try{
  $null=Invoke-RestMethod -Uri 'https://cloud-api.yandex.net/v1/disk/' -Headers @{Authorization='OAuth '+$token} -TimeoutSec 15
  return $true
 }catch{
  $code=if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{0}
  Msg "OAuth не прошёл проверку: HTTP $code. Проверьте токен и разрешение disk:read." 'Red'
  return $false
 }
}
function Check-Dav($creds){
 $script:davCheckReason='network'
 for($attempt=1;$attempt -le 2;$attempt++){
  $handler=[Net.Http.HttpClientHandler]::new()
  $handler.Credentials=[Net.NetworkCredential]::new($creds.Login,$creds.Password)
  $handler.PreAuthenticate=$true
  $client=[Net.Http.HttpClient]::new($handler)
  $client.Timeout=[TimeSpan]::FromSeconds(15)
  $request=$null;$response=$null
  try{
   $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new('PROPFIND'),'https://webdav.yandex.ru/')
   $null=$request.Headers.TryAddWithoutValidation('Depth','0')
   $response=$client.SendAsync($request).GetAwaiter().GetResult()
   $code=[int]$response.StatusCode
   if($code -eq 207){$script:davCheckReason='ok';return $true}
   if($code -eq 401 -or $code -eq 403){
    $script:davCheckReason='auth'
    Msg "WebDAV: HTTP $code (ошибка авторизации или доступа)." 'Red'
    return $false
   }
   Msg "WebDAV: HTTP $code (ошибка сервера, это не обязательно проблема пароля)." 'Yellow'
  }catch{
   $message=$_.Exception.GetBaseException().Message
   Msg "WebDAV: ошибка соединения ($message). Попытка $attempt из 2." 'Yellow'
  }finally{
   if($request){$request.Dispose()};if($response){$response.Dispose()}
   $client.Dispose()
  }
  if($attempt -lt 2){Start-Sleep -Seconds 2}
 }
 return $false
}
function Save-Auth($c) {
 if((Read-Host 'Сохранить проверенные ключи для текущего пользователя Windows? (y/n)') -ne 'y'){return}
 $record=@{}
 if($c.Token){$record.Oauth=[pscredential]::new('OAuth',(ConvertTo-SecureString $c.Token -AsPlainText -Force))}
 if($c.Password){$record.Dav=[pscredential]::new($c.Login,(ConvertTo-SecureString $c.Password -AsPlainText -Force))}
 $record | Export-Clixml -LiteralPath $secrets
 Msg 'Проверенные ключи сохранены зашифрованными.' 'Green'
}
function Verified-Auth($mode){
 $c=Auth $mode
 for($try=1;$try -le 3;$try++){
  if($mode -ne 'WebDAV' -and -not $c.Token){$c.Token=[Net.NetworkCredential]::new('',(Read-Host 'OAuth-токен' -AsSecureString)).Password}
  if($mode -eq 'WebDAV' -and (-not $c.Login -or -not $c.Password)){
   $c.Login=(Read-Host 'Логин Яндекса без @yandex.ru').Trim()
   if($c.Login -match '@'){$c.Login=($c.Login -split '@')[0]}
   $c.Password=[Net.NetworkCredential]::new('',(Read-Host 'Пароль приложения WebDAV' -AsSecureString)).Password
  }
  $valid=if($mode -eq 'WebDAV'){Check-Dav $c}else{Check-Api $c.Token}
  if($valid){if(-not $c.Saved){Save-Auth $c};return $c}
  if($try -eq 3){throw 'Три неудачных попытки входа.'}
  if((Read-Host 'Повторить ввод данных? (y/n)') -ne 'y'){throw 'Вход отменён.'}
  $c=New-Auth $mode
 }
}
function Ensure-Dav {
 if($script:davReady){return $true}
 if($script:davDeclined){return $false}
 Msg 'API не смог скачать оригинал. Можно включить резервный WebDAV.' 'Yellow'
 if((Read-Host 'Ввести логин и пароль WebDAV? (y/n)') -ne 'y'){$script:davDeclined=$true;return $false}
 for($try=1;$try -le 3;$try++){
  $c=@{Login=(Read-Host 'Логин Яндекса БЕЗ @yandex.ru').Trim();Password=[Net.NetworkCredential]::new('',(Read-Host 'Пароль приложения WebDAV' -AsSecureString)).Password}
  if($c.Login -match '@'){$c.Login=($c.Login -split '@')[0]}
  if(Check-Dav $c){
   $script:davReady=$true
   $script:davLogin=$c.Login;$script:davPassword=$c.Password
   $script:http.Dispose()
   $handler=[Net.Http.HttpClientHandler]::new()
   $handler.Credentials=[Net.NetworkCredential]::new($c.Login,$c.Password)
   $handler.PreAuthenticate=$true
   $script:http=[Net.Http.HttpClient]::new($handler)
   if((Read-Host 'Сохранить также WebDAV для будущих запусков? (y/n)') -eq 'y'){
    $record=@{Oauth=[pscredential]::new('OAuth',(ConvertTo-SecureString $script:token -AsPlainText -Force));Dav=[pscredential]::new($c.Login,(ConvertTo-SecureString $c.Password -AsPlainText -Force))}
    $record | Export-Clixml -LiteralPath $secrets
   }
   return $true
  }
  if($try -lt 3 -and (Read-Host 'Повторить WebDAV? (y/n)') -ne 'y'){break}
 }
 return $false
}
while($true){
 Msg '============ YandexDiskBackup ============' 'Cyan'
 Msg '1 — Скачать весь Диск / продолжить недостающие файлы'
 Msg '2 — Где получить ключи'
 Msg '3 — Сбросить сохранённые ключи'
 Msg '4 — Режим: Автоматически / Только API / Только WebDAV'
 Msg '0 — Выход'
 $option=Read-Host 'Выбор [Enter = 1]'
 if($option -eq '0'){break}
 if($option -eq '2'){
  Msg 'Логин: имя учётной записи без @yandex.ru (например ivan123).'
  Msg 'Пароль WebDAV: https://id.yandex.ru/security/app-passwords'
  Msg 'OAuth: https://oauth.yandex.ru/ — приложение с разрешением disk:read.'
  Msg 'Инструкция: https://yandex.ru/dev/id/doc/ru/tokens/debug-token'
  Read-Host 'Enter для продолжения' | Out-Null;continue
 }
 if($option -eq '3'){Remove-Item -LiteralPath $secrets -Force -ErrorAction SilentlyContinue;Msg 'Ключи сброшены. При следующем запуске ввод будет повторён.' 'Green';continue}
 if($option -and $option -notin @('1','4')){continue}
 Msg 'Режимы: 1 — Автоматически (API, затем WebDAV); 2 — Только API; 3 — Только WebDAV' 'Cyan'
 $modeChoice=Read-Host 'Выберите режим [Enter = 1]'
 $script:mode=switch($modeChoice){'2'{'API'} '3'{'WebDAV'} default {'Auto'}}
 $script:http=$null
 try{
  $default=if(Test-Path -LiteralPath $config){(Get-Content -LiteralPath $config -Raw).Trim()}else{Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'YandexDiskBackup'}
  $entered=Read-Host ('Папка для резервной копии [Enter = '+$default+']')
  $folder=if($entered.Trim()){[Environment]::ExpandEnvironmentVariables($entered.Trim('" '))}else{$default}
  $folder=[IO.Path]::GetFullPath($folder)
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  Set-Content -LiteralPath $config -Value $folder -Encoding utf8
  $creds=Verified-Auth $script:mode;$script:token=$creds.Token
  $handler=[Net.Http.HttpClientHandler]::new()
  if($script:mode -eq 'WebDAV' -or ($script:mode -eq 'Auto' -and $creds.Password)){$handler.Credentials=[Net.NetworkCredential]::new($creds.Login,$creds.Password)}
  $handler.PreAuthenticate=$true
  $script:davReady=($script:mode -eq 'WebDAV')
  $script:davDeclined=$false
  if($script:mode -eq 'Auto' -and $creds.Login -and $creds.Password){
   if(Check-Dav $creds){$script:davReady=$true;Msg 'Сохранённый WebDAV также проверен.' 'Green'}
   else{Msg 'Сохранённый WebDAV не работает. При необходимости запросим новые данные.' 'Yellow'}
  }
  $script:http=[Net.Http.HttpClient]::new($handler)
  $script:count=[ordered]@{Total=0;Existing=0;Downloaded=0;Failed=0;Conflicts=0}
  $script:log=Join-Path $folder '_backup-status.tsv'
  if(-not(Test-Path -LiteralPath $script:log)){Set-Content -LiteralPath $script:log -Value (@('Time','Result','RemotePath','Bytes') -join [char]9) -Encoding utf8}
  if($script:mode -eq 'WebDAV'){ Walk-Dav 'https://webdav.yandex.ru/' $folder }
  else{ Walk 'disk:/' $folder }
  Msg 'ИТОГИ:' 'Cyan'
  Msg ('Обработано: '+$script:count.Total+' | скачано: '+$script:count.Downloaded+' | уже было: '+$script:count.Existing+' | не скачано: '+$script:count.Failed+' | конфликты: '+$script:count.Conflicts) 'Cyan'
  foreach($key in $script:count.Keys){Msg ($key+': '+$script:count[$key])}
  Msg ('Резервная копия: '+$folder) 'Green'
 }catch{Msg ('ОШИБКА: '+$_.Exception.Message) 'Red'}
 finally{if($script:http){$script:http.Dispose()};Remove-Variable token -Scope Script -ErrorAction SilentlyContinue}
 Read-Host 'Enter для меню' | Out-Null
}
