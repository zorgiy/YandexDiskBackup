#requires -Version 7.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$homeDir=Join-Path $env:LOCALAPPDATA 'YandexDiskBackup'
New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
$config=Join-Path $homeDir 'folder.txt'
$secrets=Join-Path $homeDir 'credentials.xml'

function FmtSize([double]$bytes){
 if($bytes -ge 1000000000){return ('{0:N2} GB' -f ($bytes/1000000000))}
 if($bytes -ge 1000000){return ('{0:N1} MB' -f ($bytes/1000000))}
 if($bytes -ge 1000){return ('{0:N1} KB' -f ($bytes/1000))}
 return ('{0:N0} B' -f $bytes)
}
function Scan-Api($remote,$folder){
 $offset=0
 do{
  $reply=Api $remote $offset
  $items=@($reply._embedded.items | Where-Object {$null -ne $_})
  foreach($item in $items){
   $target=Join-Path $folder (SafeName $item.name)
   if($item.type -eq 'dir'){Scan-Api ([string]$item.path) $target;continue}
   if($item.type -ne 'file'){continue}
   $size=[long]$item.size
   $script:inventory.Add([pscustomobject]@{Remote=[string]$item.path;Local=$target;Size=$size}) | Out-Null
   $script:totalBytes+=$size
  }
  $offset+=$items.Count
 }while($items.Count -gt 0 -and $offset -lt [int]$reply._embedded.total)
}
function Scan-Dav($url,$folder){
 $request=$null;$response=$null
 try{
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new('PROPFIND'),$url)
  $null=$request.Headers.TryAddWithoutValidation('Depth','1')
  $response=$script:http.SendAsync($request).GetAwaiter().GetResult()
  if([int]$response.StatusCode -ne 207){throw "Сканирование WebDAV: HTTP $([int]$response.StatusCode)"}
  [xml]$doc=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $ns=[Xml.XmlNamespaceManager]::new($doc.NameTable);$ns.AddNamespace('d','DAV:')
  $self=([uri]$url).AbsolutePath.TrimEnd('/')
  foreach($node in $doc.SelectNodes('//d:response',$ns)){
   $href=$node.SelectSingleNode('d:href',$ns);if(-not $href){continue}
   $uri=[uri]::new([uri]$url,[string]$href.InnerText)
   if($uri.AbsolutePath.TrimEnd('/') -eq $self){continue}
   $name=SafeName ([uri]::UnescapeDataString($uri.AbsolutePath.TrimEnd('/').Split('/')[-1]))
   $target=Join-Path $folder $name
   if($node.SelectSingleNode('.//d:resourcetype/d:collection',$ns)){Scan-Dav $uri.AbsoluteUri $target;continue}
   $sizeNode=$node.SelectSingleNode('.//d:getcontentlength',$ns)
   if(-not $sizeNode){continue}
   $size=[long]$sizeNode.InnerText
   $script:inventory.Add([pscustomobject]@{Remote=('disk:'+ [uri]::UnescapeDataString($uri.AbsolutePath));Local=$target;Size=$size}) | Out-Null
   $script:totalBytes+=$size
  }
 }finally{if($request){$request.Dispose()};if($response){$response.Dispose()}}
}
function Run-Inventory {
 $script:started=Get-Date
 $script:processedBytes=[long]0
 $script:downloadedBytes=[long]0
 $script:lastMethod='—'
 $script:count=[ordered]@{Total=0;Existing=0;Downloaded=0;Failed=0;Conflicts=0}
 $script:inventory=[Collections.Generic.List[object]]::new()
 $script:totalBytes=[long]0
 Msg 'Сканирование всего Диска: подсчёт файлов и размера...' 'Cyan'
 if($script:mode -eq 'WebDAV'){Scan-Dav 'https://webdav.yandex.ru/' $folder}else{Scan-Api 'disk:/' $folder}
 $script:totalFiles=$script:inventory.Count
 Msg ("Найдено: {0} файлов, общий размер {1}." -f $script:totalFiles,(FmtSize $script:totalBytes)) 'Green'
 $script:dashboardActive=$true
 $script:currentFolder='Резервная копия';$script:currentFile='—';$script:lastStatus='Начало восстановления'
 Draw-Dashboard
 foreach($entry in $script:inventory){
  $script:count.Total++
  $script:currentFolder=[IO.Path]::GetDirectoryName($entry.Local)
  $script:currentFile=[IO.Path]::GetFileName($entry.Local)
  $script:remainingHere=$script:totalFiles-$script:count.Total
  $size=[long]$entry.Size
  $parent=[IO.Path]::GetDirectoryName($entry.Local)
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  if(Test-Path -LiteralPath $entry.Local){
   if((Get-Item -LiteralPath $entry.Local).Length -eq $size){
    $script:count.Existing++
    $script:processedBytes+=$size
    $script:lastStatus='Уже сохранён — пропущен'
    Draw-Dashboard
    continue
   }
   $script:count.Conflicts++
   $script:lastStatus='Конфликт: локальный файл другого размера'
   Draw-Dashboard
   continue
  }
  $script:lastStatus='Скачивание...'
  Draw-Dashboard
  $status=Get-File $entry.Remote $entry.Local $size
  if($status -eq 'OK'){
   $script:count.Downloaded++
   $script:downloadedBytes+=$size
   $script:processedBytes+=$size
   $script:lastStatus='Оригинал успешно скачан'
  }else{
   $script:count.Failed++
   $script:lastStatus=Pretty-Error $status
  }
  Add-Content -LiteralPath $script:log -Value (@((Get-Date -Format o),$status,$entry.Remote,$size) -join [char]9) -Encoding utf8
  Draw-Dashboard
 }
}

function Draw-Dashboard {
 try { Clear-Host } catch {}
 Write-Host '========== YandexDiskBackup | ВОССТАНОВЛЕНИЕ ==========' -ForegroundColor Cyan
 Write-Host ('Режим: '+$script:mode+'    Способ: '+$script:lastMethod)
 Write-Host ('Папка: '+$script:currentFolder)
 Write-Host ''
 Write-Host ('Файл: '+$script:currentFile) -ForegroundColor White
 Write-Host ('Статус: '+$script:lastStatus) -ForegroundColor Yellow
 Write-Host ''
 Write-Host ('Обработано: {0}    Скачано: {1}    Уже было: {2}' -f $script:count.Total,$script:count.Downloaded,$script:count.Existing) -ForegroundColor Green
 $pct=if($script:totalFiles -gt 0){100*$script:count.Total/$script:totalFiles}else{100}
 $done=[int][math]::Floor($pct/5)
 $bar=('█'*$done)+('░'*(20-$done))
 Write-Host ('Файлы: {0}/{1}   [{2}] {3:N1}%' -f $script:count.Total,$script:totalFiles,$bar,$pct) -ForegroundColor Cyan
 Write-Host ('Сохранено по размеру: {0} / {1}' -f (FmtSize $script:processedBytes),(FmtSize $script:totalBytes)) -ForegroundColor Green
 Write-Host ('Скачано за запуск: {0} | Время: {1:hh\:mm\:ss}' -f (FmtSize $script:downloadedBytes),((Get-Date)-$script:started))
 Write-Host ('Ошибки: {0}    Конфликты: {1}    Осталось файлов: {2}' -f $script:count.Failed,$script:count.Conflicts,($script:totalFiles-$script:count.Total)) -ForegroundColor Cyan
 Write-Host ''
 Write-Host 'Подробная история сохраняется в _backup-status.tsv'
 Write-Host 'Для остановки нажмите Ctrl+C.'
}
function Msg($m,$c='Gray'){
 $value=[string]$m
 if($script:dashboardActive){
  if($value -match '^ПАПКА'){ $script:currentFolder=$value -replace '^ПАПКА(?: WebDAV)?:\s*','';$script:currentFile='—';$script:lastStatus='Поиск файлов';Draw-Dashboard }
  elseif($value -match '^СКАЧИВАЕМ:'){ $script:currentFile=$value -replace '^СКАЧИВАЕМ:\s*','';$script:lastStatus='Скачивание...';Draw-Dashboard }
  elseif($value -match 'УСПЕШНО:'){ $script:lastStatus='Успешно скачан оригинал' }
  elseif($value -match 'НЕ СКАЧАН:'){ $script:lastStatus=$value.Trim() }
  elseif($value -match 'НЕ ПЕРЕЗАПИСАН|Размер отличается'){ $script:lastStatus=$value.Trim() }
  return
 }
 Write-Host $m -ForegroundColor $c
}

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
 $script:remainingHere=[Math]::Max(0,$remainingInFolder)
 if($script:dashboardActive){Draw-Dashboard;return}
 Msg ("  ПРОГРЕСС: обработано {0} | скачано {1} | уже было {2} | ошибок {3} | осталось в папке {4}" -f $script:count.Total,$script:count.Downloaded,$script:count.Existing,$script:count.Failed,$script:remainingHere) 'DarkCyan'
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
 $script:lastMethod='WebDAV'
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
 $script:lastMethod='API'
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
  if(-not (Ensure-Dav)){$script:dashboardActive=$true;return $result}
  $script:dashboardActive=$true
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
    if((Get-Item -LiteralPath $target).Length -eq $size){$script:count.Existing++;$script:lastStatus='Уже сохранён, пропускаем';$script:currentFile=[IO.Path]::GetFileName($target);Show-ProgressLine $remainingHere;continue}
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
  if($mode -eq 'WebDAV' -and $script:davCheckReason -eq 'network'){
   throw 'WebDAV недоступен по сети. Пароль не признан неправильным. Попробуйте позже или выберите режим API.'
  }
  if($try -eq 3){throw 'Три неудачных попытки входа.'}
  if((Read-Host 'Повторить ввод данных? (y/n)') -ne 'y'){throw 'Вход отменён.'}
  $c=New-Auth $mode
 }
}
function Ensure-Dav {
 $script:dashboardActive=$false
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
$script:mode='Auto'
$modePath=Join-Path $homeDir 'mode.txt'
if(Test-Path -LiteralPath $modePath){
 $modeSaved=(Get-Content -LiteralPath $modePath -Raw).Trim()
 if($modeSaved -in @('API','WebDAV','Auto')){$script:mode=$modeSaved}
}
while($true){
 $script:dashboardActive=$false
 try{Clear-Host}catch{}
 Msg '============ YandexDiskBackup ============' 'Cyan'
 Msg '1 — Скачать весь Диск / продолжить недостающие файлы'
 Msg '2 — Где получить ключи'
 Msg '3 — Сменить аккаунт Яндекса (сбросить вход)'
 Msg ('4 — Настроить режим (текущий: '+$(switch($script:mode){'API'{'Только API'} 'WebDAV'{'Только WebDAV'} default{'Автоматически'}})+')')
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
 if($option -eq '3'){
  Msg 'Будут удалены сохранённые логин, пароль приложения WebDAV и OAuth-токен.' 'Yellow'
  Msg 'Резервные копии и настройки режима останутся без изменений.'
  if((Read-Host 'Сбросить данные аккаунта? (y/n)').Trim().ToLowerInvariant() -eq 'y'){
   if(Test-Path -LiteralPath $secrets){
    try{
     Remove-Item -LiteralPath $secrets -Force -ErrorAction Stop
     Msg 'Аккаунт отключён. Логин и ключи удалены.' 'Green'
     Msg 'При следующем подключении можно войти в другой аккаунт Яндекса.' 'Green'
    }catch{Msg ('Ошибка сброса аккаунта: '+$_.Exception.Message) 'Red'}
   }else{Msg 'Сохранённого аккаунта нет. При подключении можно указать другой.' 'Yellow'}
  }else{Msg 'Сброс отменён. Данные входа не изменены.'}
  Read-Host 'Нажмите Enter, чтобы вернуться в меню' | Out-Null
  continue
 }
 if($option -eq '4'){
  Msg '1 — Автоматически (API, затем WebDAV)' 'Cyan'
  Msg '2 — Только API'
  Msg '3 — Только WebDAV'
  $modeChoice=Read-Host 'Выберите режим [Enter = оставить текущий]'
  if($modeChoice -in @('1','2','3')){
   $script:mode=switch($modeChoice){'2'{'API'} '3'{'WebDAV'} default{'Auto'}}
   Set-Content -LiteralPath (Join-Path $homeDir 'mode.txt') -Value $script:mode -Encoding utf8
   Msg 'Настройка режима сохранена.' 'Green'
  }
  continue
 }
 if($option -and $option -ne '1'){continue}
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
  $script:log=Join-Path $folder '_backup-status.tsv'
  if(-not(Test-Path -LiteralPath $script:log)){Set-Content -LiteralPath $script:log -Value (@('Time','Result','RemotePath','Bytes') -join [char]9) -Encoding utf8}
  Run-Inventory
  $script:dashboardActive=$false
  try{Clear-Host}catch{}
  Msg 'ИТОГИ:' 'Cyan'
  Msg ('Обработано: '+$script:count.Total+' | скачано: '+$script:count.Downloaded+' | уже было: '+$script:count.Existing+' | не скачано: '+$script:count.Failed+' | конфликты: '+$script:count.Conflicts) 'Cyan'
  foreach($key in $script:count.Keys){Msg ($key+': '+$script:count[$key])}
  Msg ('Резервная копия: '+$folder) 'Green'
 }catch{$script:dashboardActive=$false;Msg ('ОШИБКА: '+$_.Exception.Message) 'Red'}
 finally{$script:dashboardActive=$false;if($script:http){$script:http.Dispose()};Remove-Variable token -Scope Script -ErrorAction SilentlyContinue}
 Read-Host 'Enter для меню' | Out-Null
}
