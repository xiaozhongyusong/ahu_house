# Windows PowerShell 5.1. Remote JavaScript is treated only as text.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Transport = $null
$script:Delay = { param($Seconds) Start-Sleep -Seconds $Seconds }
$script:Notifier = $null

function Initialize-CampusContext {
    param([string]$Root)
    $script:AppRoot = [IO.Path]::GetFullPath($Root)
    $script:DataRoot = Join-Path $script:AppRoot '数据'
    $script:CredentialPath = Join-Path $script:DataRoot 'credentials.clixml'
    $script:StatePath = Join-Path $script:DataRoot 'state.json'
    $script:DisabledPath = Join-Path $script:DataRoot 'disabled.flag'
    $script:NoticePath = Join-Path $script:AppRoot '需要更新设置.txt'
    $script:Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:TaskName = 'CampusNetAutoLogin-' + $script:Sid
    $script:TaskMarker = 'CampusNetAutoLogin/v1 | ' + $script:AppRoot
    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    }
}

function Protect-CampusData {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @($script:Sid, 'S-1-5-18', 'S-1-5-32-544')) {
        $sidObject = New-Object Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sidObject, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($script:DataRoot, $acl)
}

function Enter-CampusLock {
    try {
        return [IO.File]::Open((Join-Path $script:DataRoot 'worker.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { return $null }
}

function New-CampusState {
    return @{ Version=1; Status=@{}; Failures=0; CooldownUntil=''; BlockReason=''; LastIp=''; LastCheck='' }
}

function Read-CampusState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return New-CampusState }
    try {
        $json = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $state = New-CampusState
        foreach ($key in @('Failures','CooldownUntil','BlockReason','LastIp','LastCheck')) {
            if ($null -ne $json.PSObject.Properties[$key]) { $state[$key] = $json.$key }
        }
        if ($null -ne $json.PSObject.Properties['Status']) {
            foreach ($item in $json.Status.PSObject.Properties) { $state.Status[$item.Name] = [string]$item.Value }
        }
        $state.Failures = [Math]::Max(0,[Math]::Min(3,[int]$state.Failures))
        return $state
    } catch { throw 'StateUnreadable' }
}

function Write-CampusState {
    param([hashtable]$State)
    $temp = $script:StatePath + '.tmp'
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $script:StatePath -Force
}

function Set-CampusStatus {
    param([hashtable]$State,[string]$Key,[string]$Value)
    # Only these fixed tokens can enter logs. No response text, URL or exception message.
    $allowedKeys = @('Authentication','Internet','Run','LoginReply','Address','Control')
    $allowedValues = @('Online','Offline','Unknown','Available','Unavailable','NotChecked',
        'Ready','NeedSetup','Disabled','NetworkWaiting','ProtocolWaiting','RetryLater',
        'Cooldown','PausedCredentials','PausedBalance','PausedAccount','PausedDecrypt',
        'Accepted','Rejected','Uncertain','Changed','Saved','Stopped','Cleared','InternalError')
    if ($Key -notin $allowedKeys -or $Value -notin $allowedValues) { throw 'InvalidLogToken' }
    if ($State.Status.ContainsKey($Key) -and $State.Status[$Key] -eq $Value) { return }
    $State.Status[$Key] = $Value
    $log = Join-Path $script:DataRoot '运行日志.log'
    $line = '{0} {1}={2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Key,$Value
    $bytes = [Text.Encoding]::UTF8.GetByteCount($line + [Environment]::NewLine) + 3
    if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length + $bytes -ge 1MB)) {
        Move-Item -LiteralPath $log -Destination ($log + '.1') -Force
    }
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

function ConvertFrom-CampusJsonp {
    param([string]$Text,[string]$Callback)
    if ($Text.Length -gt 524288) { throw 'ResponseTooLarge' }
    $pattern = '\A\s*' + [regex]::Escape($Callback) + '\s*\(\s*(?<json>\{.*\})\s*\)\s*;?\s*\z'
    $match = [regex]::Match($Text,$pattern,[Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'InvalidJsonp' }
    try { $data = $match.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'InvalidJsonp' }
    if ($null -eq $data -or $data -is [Array]) { throw 'InvalidJsonp' }
    return $data
}

function Get-CampusProperty {
    param($Object,[string]$Name,[object]$Default='')
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function New-CampusQuery {
    param([System.Collections.IDictionary]$Parameters)
    $parts = foreach ($key in $Parameters.Keys) {
        [Uri]::EscapeDataString([string]$key) + '=' + [Uri]::EscapeDataString([string]$Parameters[$key])
    }
    return ($parts -join '&')
}

function Invoke-CampusText {
    param([string]$Uri)
    if ($null -ne $script:Transport) { return & $script:Transport $Uri }
    $response=$null; $stream=$null; $memory=$null
    try {
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Proxy = $null
        $request.Timeout = 10000
        $request.ReadWriteTimeout = 10000
        $request.AllowAutoRedirect = $false
        $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $request.UserAgent = 'CampusNetAutoLogin/1.0'
        $request.Headers['Cache-Control'] = 'no-cache'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw 'RequestFailed' }
        $stream = $response.GetResponseStream()
        $memory = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 8192
        while ($true) {
            $remaining = 10000 - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'RequestFailed' }
            if ($stream.CanTimeout) { $stream.ReadTimeout = $remaining }
            $count = $stream.Read($buffer,0,$buffer.Length)
            if ($count -eq 0) { break }
            if ($memory.Length + $count -gt 524288 -or $watch.Elapsed.TotalSeconds -gt 10) {
                throw 'RequestFailed'
            }
            $memory.Write($buffer,0,$count)
        }
        $encoding = [Text.Encoding]::UTF8
        if ($Uri -match '/(?:a79\.htm|a41\.js|config\.js)(?:\?|$)') {
            $encoding = [Text.Encoding]::GetEncoding('gb18030')
        }
        if ($response.CharacterSet -match '^(utf-8|gb2312|gbk|gb18030)$') {
            $encoding = [Text.Encoding]::GetEncoding($response.CharacterSet)
        }
        return $encoding.GetString($memory.ToArray())
    } catch { throw 'RequestFailed' }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $response) { $response.Close() }
        $Uri=$null
    }
}

function Get-CampusVariable {
    param([string]$Text,[string]$Name,[string]$Default='')
    $pattern = '\b' + [regex]::Escape($Name) + '\s*=\s*[''"](?<value>[^''"]*)[''"]'
    $match = [regex]::Match($Text,$pattern)
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return $Default
}

function Test-CampusIpv4 {
    param([string]$Ip)
    if ($Ip -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { return $false }
    $address=$null
    if (-not [Net.IPAddress]::TryParse($Ip,[ref]$address)) { return $false }
    $octets=$address.GetAddressBytes()
    return ($octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168))
}

function Get-CampusPageContext {
    $html = Invoke-CampusText ('http://172.16.253.3/a79.htm?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if ($html -notmatch 'Dr\.COM(?:1\.0)?WebLoginID_' -or $html -notmatch 'page\.run') {
        throw 'UnsupportedPage'
    }
    $ip=''
    foreach ($name in @('v46ip','ss5','v4ip')) {
        $candidate=Get-CampusVariable $html $name
        if (Test-CampusIpv4 $candidate) { $ip=$candidate; break }
    }
    if (-not $ip) { throw 'NoCampusIp' }
    $mac=(Get-CampusVariable $html 'ss4' '000000000000') -replace '[:-]',''
    if ($mac -notmatch '^[0-9a-fA-F]{12}$') { $mac='000000000000' }
    $ipv6=Get-CampusVariable $html 'myv6ip'
    $ipAddress=$null
    if (-not [Net.IPAddress]::TryParse($ipv6,[ref]$ipAddress) -or
        $ipAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) { $ipv6='' }
    $version=Get-CampusVariable $html 'fileVersion'
    if ($version -notmatch '^\d{1,20}$') { throw 'UnsupportedPage' }
    return @{ Ip=$ip; Mac=$mac; Ipv6=$ipv6; FileVersion=$version; AcIp='172.16.253.1'; AcName='' }
}

function Get-CampusAuthentication {
    # The gateway can cache the fixed status URL for a short time. A changing
    # query value is required so a successful login is not reported as stale
    # offline state on the next check.
    $uri='http://172.16.253.3/drcom/chkstatus?callback=campusStatus&_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $data=ConvertFrom-CampusJsonp (Invoke-CampusText $uri) 'campusStatus'
    $result=[string](Get-CampusProperty $data 'result')
    if ($result -notin @('0','1')) { throw 'UnknownStatus' }
    $mac=[string](Get-CampusProperty $data 'ss4' '000000000000')
    if ($mac -notmatch '^[0-9a-fA-F]{12}$') { $mac='000000000000' }
    return @{ Online=($result -eq '1'); Mac=$mac; Ip=[string](Get-CampusProperty $data 'v46ip') }
}

function ConvertTo-CampusIpNumber {
    param([string]$Ip)
    $octets=([Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    if ($octets.Length -ne 4) { throw 'UnsupportedPage' }
    return ([long]$octets[0]*16777216 + [long]$octets[1]*65536 + [long]$octets[2]*256 + $octets[3])
}

function Get-CampusPortalParameters {
    param([hashtable]$Context)
    $source=Invoke-CampusText ('http://172.16.253.3/a41.js?version=' + $Context.FileVersion)
    $jsVersion=Get-CampusVariable $source 'jsVersion'
    $program=[regex]::Match($source,'var\s+page\s*=\s*\{.*?\bname\s*:\s*[''"](?<name>\d+)[''"]',
        [Text.RegularExpressions.RegexOptions]::Singleline).Groups['name'].Value
    if ($jsVersion -notmatch '^\d+\.\d+\.\d+$' -or -not $program) { throw 'UnsupportedPage' }
    $config=Invoke-CampusText ('http://172.16.253.3:801/eportal/extern/' + $program + '/config.js?version=' + $Context.FileVersion)
    if ($config -notmatch '\bpageSetting\s*=\s*2\s*;') { throw 'UnsupportedPage' }
    $entries=@{}
    foreach ($match in [regex]::Matches($config,'\bipPageAry\[(?<index>\d+)\]\s*=\s*["''](?<fields>[^"'']+)["'']\s*;')) {
        $entries[[int]$match.Groups['index'].Value]=$match.Groups['fields'].Value.Split('|')
    }
    if (-not $entries.ContainsKey(0)) { throw 'UnsupportedPage' }
    $selected=$entries[0]; $selectedIndex=0
    $current=ConvertTo-CampusIpNumber $Context.Ip
    foreach ($index in @($entries.Keys | Sort-Object)) {
        if ($index -eq 0) { continue }
        $fields=$entries[$index]
        if ($fields.Length -lt 8 -or $fields[5] -ne '1') { continue }
        $starts=$fields[1].Split(';'); $ends=$fields[2].Split(';')
        if ($starts.Length -ne $ends.Length) { throw 'UnsupportedPage' }
        $found=$false
        for($j=0;$j -lt $starts.Length;$j++) {
            if ($current -ge (ConvertTo-CampusIpNumber $starts[$j]) -and
                $current -le (ConvertTo-CampusIpNumber $ends[$j])) { $found=$true; break }
        }
        if ($found) { $selected=$fields; $selectedIndex=$index; break }
    }
    if ($selected.Length -lt 8 -or $selected[5] -ne '1' -or $selected[6] -ne '1') {
        throw 'UnsupportedAccessMethod'
    }
    return @{ LoginMethod='1'; JsVersion=$jsVersion; PageIndex=$selectedIndex }
}

function Get-CampusCredential {
    $credential=Import-Clixml -LiteralPath $script:CredentialPath
    if ($credential -isnot [Management.Automation.PSCredential] -or -not $credential.UserName -or
        $credential.Password.Length -eq 0) { throw 'CredentialUnreadable' }
    # Force DPAPI decryption here, before constructing any request.
    $ptr=[IntPtr]::Zero
    try { $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
    return $credential
}

function Save-CampusCredential {
    param([Management.Automation.PSCredential]$Credential)
    Protect-CampusData
    $temp=$script:CredentialPath + '.tmp'
    $Credential | Export-Clixml -LiteralPath $temp -Encoding UTF8
    $check=Import-Clixml -LiteralPath $temp
    if ($check -isnot [Management.Automation.PSCredential] -or $check.UserName -cne $Credential.UserName) {
        throw 'CredentialUnreadable'
    }
    Move-Item -LiteralPath $temp -Destination $script:CredentialPath -Force
    $Credential=$null; $check=$null
}

function Invoke-CampusLogin {
    param([hashtable]$Context,[hashtable]$Portal,[Management.Automation.PSCredential]$Credential)
    $ptr=[IntPtr]::Zero; $password=$null; $parameters=$null; $uri=$null
    try {
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $parameters=[ordered]@{
            c='Portal'; a='login'; callback='campusLogin'
            login_method=$Portal.LoginMethod; user_account=$Credential.UserName
            user_password=$password; wlan_user_ip=$Context.Ip; wlan_user_ipv6=$Context.Ipv6
            wlan_user_mac=$Context.Mac; wlan_ac_ip=$Context.AcIp; wlan_ac_name=$Context.AcName
            jsVersion=$Portal.JsVersion
        }
        $uri='http://172.16.253.3:801/eportal/?' + (New-CampusQuery $parameters)
        return ConvertFrom-CampusJsonp (Invoke-CampusText $uri) 'campusLogin'
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        if ($null -ne $parameters) { $parameters.Clear() }
        $password=$null; $uri=$null; $Credential=$null
    }
}

function Get-CampusLoginClassification {
    param($Reply)
    if ([string](Get-CampusProperty $Reply 'result') -in @('1','ok')) { return 'Accepted' }
    $messages=New-Object 'Collections.Generic.List[string]'
    foreach ($key in @('msg','message','errcode','error')) {
        $value=[string](Get-CampusProperty $Reply $key)
        if ($value.Length -gt 4096) { continue }
        $messages.Add($value)
        if ($value -match '^[A-Za-z0-9+/]+={0,2}$' -and $value.Length % 4 -eq 0) {
            try {
                $bytes=[Convert]::FromBase64String($value)
                $messages.Add([Text.Encoding]::UTF8.GetString($bytes))
                $messages.Add([Text.Encoding]::GetEncoding('gb18030').GetString($bytes))
            } catch {}
        }
    }
    $message=$messages -join ' '
    if ($message -match '欠费|余额不足|费用不足|insufficient.{0,20}(balance|credit)|arrears|overdue') {
        return 'Balance'
    }
    if ($message -match '停用|禁用|冻结|已到期|过期|out of service|account.{0,20}(disabled|suspended|expired)') {
        return 'Account'
    }
    if ([string](Get-CampusProperty $Reply 'ret_code') -eq '1' -or
        $message -match '账号或密码|帐号或密码|账户或密码|用户名或密码|用户名不存在|账号不存在|密码.{0,8}(错误|不对|无效)|(invalid|incorrect).{0,15}(password|credentials)|user.{0,8}not.{0,8}exist') {
        return 'Credentials'
    }
    return 'Temporary'
}

function Test-CampusInternet {
    # Try multiple probes; any one succeeding proves external reachability.
    $probes=@(
        'https://www.baidu.com',
        'http://www.baidu.com',
        'https://connect.rom.miui.com/generate_204',
        'http://g.cn/generate_204'
    )
    foreach($probe in $probes) {
        try {
            $text=Invoke-CampusText $probe
            if ($probe -like '*generate_204*') {
                if ($text.Trim() -eq '') { return $true }
            } else {
                if ($text.Length -gt 100) { return $true }
            }
        } catch {}
    }
    return $false
}

function Show-CampusNotice {
    param([string]$Reason)
    $message='校园网自动认证已暂停。请双击“03-更新账号密码”，或查看“05-查看状态”。'
    if ($Reason -eq 'Balance') { $message='校园网提示欠费或余额不足，已暂停自动认证。处理后双击“03-更新账号密码”恢复。' }
    if ($Reason -eq 'Account') { $message='校园网提示账号停用或到期，已暂停自动认证。处理后双击“03-更新账号密码”恢复。' }
    if ($Reason -eq 'Decrypt') { $message='本机无法解密已保存凭据，已暂停自动认证。请双击“03-更新账号密码”重新保存。' }
    Set-Content -LiteralPath $script:NoticePath -Value $message -Encoding UTF8
    if ($null -ne $script:Notifier) { & $script:Notifier $Reason; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon=New-Object Windows.Forms.NotifyIcon
        $icon.Icon=[Drawing.SystemIcons]::Warning
        $icon.Visible=$true
        $icon.BalloonTipTitle='校园网自动登录'
        $icon.BalloonTipText=$message
        $icon.ShowBalloonTip(8000)
        Start-Sleep -Seconds 8
        $icon.Dispose()
    } catch {}
}

function Set-CampusPermanentPause {
    param([hashtable]$State,[string]$Reason)
    $first=($State.BlockReason -ne $Reason)
    $State.BlockReason=$Reason
    Set-CampusStatus $State 'Run' ('Paused' + $Reason)
    if ($first) { Show-CampusNotice $Reason }
}

function Add-CampusTemporaryFailure {
    param([hashtable]$State)
    $State.Failures=[int]$State.Failures + 1
    if ($State.Failures -ge 3) {
        $State.Failures=0
        $State.CooldownUntil=[DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
        Set-CampusStatus $State 'Run' 'Cooldown'
    } else { Set-CampusStatus $State 'Run' 'RetryLater' }
}

function Set-CampusOnline {
    param([hashtable]$State)
    Set-CampusStatus $State 'Authentication' 'Online'
    $State.Failures=0
    $State.CooldownUntil=''
    if (Test-CampusInternet) { Set-CampusStatus $State 'Internet' 'Available' }
    else { Set-CampusStatus $State 'Internet' 'Unavailable' }
    if ($State.BlockReason) { Set-CampusStatus $State 'Run' ('Paused' + $State.BlockReason) }
    else { Set-CampusStatus $State 'Run' 'Ready' }
}

function Invoke-CampusCheck {
    param([hashtable]$State,[switch]$ReadOnly)
    $State.LastCheck=[DateTimeOffset]::Now.ToString('o')
    if (-not $ReadOnly -and (Test-Path -LiteralPath $script:DisabledPath)) {
        Set-CampusStatus $State 'Run' 'Disabled'; return
    }
    if (-not $ReadOnly -and -not (Test-Path -LiteralPath $script:CredentialPath)) {
        Set-CampusStatus $State 'Run' 'NeedSetup'; return
    }
    try {
        $context=Get-CampusPageContext
        $auth=Get-CampusAuthentication
    } catch {
        Set-CampusStatus $State 'Authentication' 'Unknown'
        Set-CampusStatus $State 'Internet' 'NotChecked'
        Set-CampusStatus $State 'Run' 'NetworkWaiting'
        return
    }
    if ($State.LastIp -and $State.LastIp -ne $context.Ip) {
        # No address itself enters the log.
        $State.Status.Remove('Address')
        Set-CampusStatus $State 'Address' 'Changed'
    }
    $State.LastIp=$context.Ip
    if ($auth.Online) { Set-CampusOnline $State; return }
    # Some Dr.COM deployments return result=0 even after successful auth.
    # Cross-check with an external HTTPS probe: if the outside world is
    # reachable, the link is up regardless of what chkstatus claims.
    if (Test-CampusInternet) {
        Set-CampusStatus $State 'Authentication' 'Online'
        $State.Failures=0
        $State.CooldownUntil=''
        Set-CampusStatus $State 'Internet' 'Available'
        if ($State.BlockReason) { Set-CampusStatus $State 'Run' ('Paused' + $State.BlockReason) }
        else { Set-CampusStatus $State 'Run' 'Ready' }
        return
    }
    Set-CampusStatus $State 'Authentication' 'Offline'
    Set-CampusStatus $State 'Internet' 'NotChecked'
    if ($ReadOnly) { Set-CampusStatus $State 'Run' 'Ready'; return }
    if ($State.BlockReason) {
        Set-CampusStatus $State 'Run' ('Paused' + $State.BlockReason); return
    }
    if ($State.CooldownUntil) {
        try { $until=[DateTimeOffset]::Parse($State.CooldownUntil) } catch { throw 'StateUnreadable' }
        if ([DateTimeOffset]::UtcNow -lt $until) { Set-CampusStatus $State 'Run' 'Cooldown'; return }
        $State.CooldownUntil=''; $State.Failures=0
    }
    # Refresh page and online state immediately before preparing authentication.
    try {
        $context=Get-CampusPageContext
        $auth=Get-CampusAuthentication
        if ($auth.Online) { Set-CampusOnline $State; return }
        if ($auth.Ip -and $auth.Ip -ne $context.Ip) { throw 'AddressMismatch' }
        if ($State.LastIp -ne $context.Ip) {
            $State.Status.Remove('Address')
            Set-CampusStatus $State 'Address' 'Changed'
        }
        $State.LastIp=$context.Ip
        if ($auth.Mac -ne '000000000000') { $context.Mac=$auth.Mac }
        $portal=Get-CampusPortalParameters $context
    } catch {
        Set-CampusStatus $State 'Run' 'ProtocolWaiting'; return
    }
    try { $credential=Get-CampusCredential }
    catch { Set-CampusPermanentPause $State 'Decrypt'; return }
    if (Test-Path -LiteralPath $script:DisabledPath) {
        $credential=$null; Set-CampusStatus $State 'Run' 'Disabled'; return
    }
    $reply=$null; $classification='Temporary'
    try {
        $reply=Invoke-CampusLogin $context $portal $credential
        $classification=Get-CampusLoginClassification $reply
        if ($classification -eq 'Accepted') { Set-CampusStatus $State 'LoginReply' 'Accepted' }
        elseif ($classification -in @('Credentials','Balance','Account')) { Set-CampusStatus $State 'LoginReply' 'Rejected' }
        else { Set-CampusStatus $State 'LoginReply' 'Uncertain' }
    } catch { Set-CampusStatus $State 'LoginReply' 'Uncertain' }
    finally { $credential=$null; $reply=$null }
    & $script:Delay 5
    if (Test-Path -LiteralPath $script:DisabledPath) { Set-CampusStatus $State 'Run' 'Disabled'; return }
    # Verify IP again so a changed address can never validate a stale login.
    $afterAuth=$null; $afterContext=$null
    try {
        $afterContext=Get-CampusPageContext
        $afterAuth=Get-CampusAuthentication
        if ($afterAuth.Online) {
            $State.LastIp=$afterContext.Ip
            Set-CampusOnline $State
            return
        }
        Set-CampusStatus $State 'Authentication' 'Offline'
    } catch { Set-CampusStatus $State 'Authentication' 'Unknown' }
    # Gateway chkstatus may lag behind the login ACK. Retry once after a short
    # delay before falling back to the external probe.
    if ($classification -eq 'Accepted') {
        & $script:Delay 3
        try {
            $afterContext=Get-CampusPageContext
            $afterAuth=Get-CampusAuthentication
            if ($afterAuth.Online) {
                $State.LastIp=$afterContext.Ip
                Set-CampusOnline $State
                Set-CampusStatus $State 'LoginReply' 'Accepted'
                return
            }
        } catch {}
    }
    # Some gateway versions acknowledge a login before chkstatus catches up.
    # If the reply was accepted and a fixed HTTPS probe succeeds, the outside
    # connection is stronger evidence than the stale transitional status.
    if ($classification -eq 'Accepted' -and (Test-CampusInternet)) {
        $State.LastIp=$context.Ip
        Set-CampusOnline $State
        Set-CampusStatus $State 'LoginReply' 'Accepted'
        return
    }
    if ($classification -in @('Credentials','Balance','Account')) {
        Set-CampusPermanentPause $State $classification
    } else { Add-CampusTemporaryFailure $State }
}

function Get-CampusOwnedTask {
    $task=Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $task -and $task.Description -cne $script:TaskMarker) { throw 'TaskNameConflict' }
    return $task
}

function New-CampusTaskXml {
    param([string]$Name=$script:TaskName)
    $escape={ param($s) [Security.SecurityElement]::Escape([string]$s) }
    $description=& $escape $script:TaskMarker
    $sid=& $escape $script:Sid
    $command=& $escape (Join-Path $env:SystemRoot 'System32\wscript.exe')
    $args=& $escape ('//B //Nologo "' + (Join-Path $script:AppRoot '程序\后台运行.vbs') + '"')
    $working=& $escape $script:AppRoot
    $start=(Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$description</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger>
    <TimeTrigger><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><StartBoundary>$start</StartBoundary><Enabled>true</Enabled></TimeTrigger>
  </Triggers>
  <Principals><Principal id="CurrentUser"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT3M</ExecutionTimeLimit></Settings>
  <Actions Context="CurrentUser"><Exec><Command>$command</Command><Arguments>$args</Arguments><WorkingDirectory>$working</WorkingDirectory></Exec></Actions>
</Task>
"@
}

function Register-CampusTask {
    $existing=Get-CampusOwnedTask
    if ($null -ne $existing) { Stop-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue }
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Xml (New-CampusTaskXml) -Force | Out-Null
    $task=Get-CampusOwnedTask
    if ($null -eq $task -or $task.Principal.LogonType -ne 'Interactive' -or
        $task.Settings.MultipleInstances -ne 'IgnoreNew' -or
        $task.Settings.DisallowStartIfOnBatteries -or $task.Settings.StopIfGoingOnBatteries) {
        throw 'TaskVerificationFailed'
    }
}

function Stop-CampusWorker {
    $runnerFile=Join-Path $script:DataRoot 'runner.json'
    if (-not (Test-Path -LiteralPath $runnerFile)) { return }
    try {
        $runner=Get-Content -LiteralPath $runnerFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runner.Sid -cne $script:Sid -or [int]$runner.Pid -eq $PID) { return }
        $process=Get-Process -Id ([int]$runner.Pid) -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$runner.StartTicks) { return }
        $cim=Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$runner.Pid)
        $owner=Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid
        $path=Join-Path $script:AppRoot '程序\CampusNet.ps1'
        if ($owner.Sid -cne $script:Sid -or $cim.CommandLine -notlike ('*"' + $path + '"*') -or
            $cim.CommandLine -notmatch '-Mode\s+Check\b') { return }
        Stop-Process -Id ([int]$runner.Pid) -Force -ErrorAction Stop
    } catch {}
}

function Disable-CampusTask {
    # Disable marker closes the race even when a manual worker is already running.
    Set-Content -LiteralPath $script:DisabledPath -Value 'disabled' -Encoding ASCII
    $task=Get-CampusOwnedTask
    if ($null -ne $task) {
        Stop-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Confirm:$false
    }
    Stop-CampusWorker
}

