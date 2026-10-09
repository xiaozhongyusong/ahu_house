param(
    [ValidateSet('Setup','Update','Check','Status','Disable','ClearCredentials','Probe')]
    [string]$Mode='Status',
    [switch]$ShowResult
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
Initialize-CampusContext (Split-Path $PSScriptRoot -Parent)

function Show-LocalMessage {
    param([string]$Message,[string]$Title='校园网小助手')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text=$Title
    $dialog.ClientSize=New-Object Drawing.Size(480,250)
    $dialog.StartPosition='CenterScreen'
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $dialog.MinimizeBox=$false
    $dialog.BackColor=[Drawing.Color]::FromArgb(250,245,252)
    $dialog.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)

    $accent=New-Object Windows.Forms.Panel
    $accent.BackColor=[Drawing.Color]::FromArgb(200,170,230)
    $accent.Dock='Top'
    $accent.Height=4
    $dialog.Controls.Add($accent)

    $heading=New-Object Windows.Forms.Label
    $heading.Text='🐾 ' + $Title
    $heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
    $heading.ForeColor=[Drawing.Color]::FromArgb(90,70,110)
    $heading.Location=New-Object Drawing.Point(28,24)
    $heading.Size=New-Object Drawing.Size(420,28)
    $dialog.Controls.Add($heading)

    $body=New-Object Windows.Forms.Label
    $body.Text=$Message
    $body.AutoSize=$false
    $body.Location=New-Object Drawing.Point(30,64)
    $body.Size=New-Object Drawing.Size(420,110)
    $body.ForeColor=[Drawing.Color]::FromArgb(120,100,140)
    $dialog.Controls.Add($body)

    $ok=New-Object Windows.Forms.Button
    $ok.Text='知道啦~'
    $ok.DialogResult=[Windows.Forms.DialogResult]::OK
    $ok.FlatStyle='Flat'
    $ok.FlatAppearance.BorderSize=0
    $ok.BackColor=[Drawing.Color]::FromArgb(200,170,230)
    $ok.ForeColor=[Drawing.Color]::White
    $ok.Location=New-Object Drawing.Point(350,190)
    $ok.Size=New-Object Drawing.Size(100,34)
    $dialog.Controls.Add($ok)
    $dialog.AcceptButton=$ok
    $dialog.ShowDialog() | Out-Null
    $dialog.Dispose()
}

function Get-LocalStatusText {
    $map=@{
        Online='已认证'; Offline='未认证'; Unknown='状态未知'
        Available='可用'; Unavailable='未通过外网探测'; NotChecked='未检查'
        Ready='检查正常'; NeedSetup='尚未设置账号密码'; Disabled='已停用'
        NetworkWaiting='校园网或服务器暂不可达，下次检查再试'
        ProtocolWaiting='页面、IP 或接入方式暂不匹配，下次检查再试'
        RetryLater='临时认证故障，下次检查再试'; Cooldown='连续三次临时故障，暂停认证 10 分钟'
        PausedCredentials='账号密码错误，自动认证已暂停'
        PausedBalance='欠费或余额不足，自动认证已暂停'
        PausedAccount='账号停用或到期，自动认证已暂停'
        PausedDecrypt='凭据无法解密，请重新设置'
        InternalError='本地程序错误，未提交新的认证'
    }
    try { $state=Read-CampusState } catch { return '状态文件无法读取。请双击「03-更新账号密码」重建设置。' }
    $run='NeedSetup'
    if ($state.Status.ContainsKey('Run')) { $run=$state.Status.Run }
    if (Test-Path -LiteralPath $script:DisabledPath) { $run='Disabled' }
    elseif (-not (Test-Path -LiteralPath $script:CredentialPath)) { $run='NeedSetup' }
    $auth='Unknown'; $internet='NotChecked'
    if ($state.Status.ContainsKey('Authentication')) { $auth=$state.Status.Authentication }
    if ($state.Status.ContainsKey('Internet')) { $internet=$state.Status.Internet }
    $taskText='未安装'
    try { $task=Get-CampusOwnedTask; if($null -ne $task){$taskText=[string]$task.State} } catch { $taskText='任务名称冲突' }
    $last='尚未检查'
    if ($state.LastCheck) {
        try { $last=([DateTimeOffset]::Parse($state.LastCheck)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    }
    $extra=''
    if ($state.CooldownUntil) {
        try { $extra="`r`n暂停至：" + ([DateTimeOffset]::Parse($state.CooldownUntil)).ToLocalTime().ToString('HH:mm:ss') } catch {}
    }
    return ("运行状态：{0}`r`n校园网认证：{1}`r`n外网探测：{2}`r`n计划任务：{3}`r`n上次检查：{4}{5}`r`n`r`n进入桌面后自动检查，此后每分钟一次。`r`n暂停认证后，请更新本地设置恢复。`r`n日志只记录状态变化，位于「数据」文件夹。" -f
        $map[$run],$map[$auth],$map[$internet],$taskText,$last,$extra)
}

function Get-LocalStatusInfo {
    $map=@{
        Online='已连上'; Offline='还没连'; Unknown='不清楚'; Available='畅通'; Unavailable='不通'; NotChecked='没查过'
        Ready='运行中'; NeedSetup='待设置'; Disabled='已停用'; NetworkWaiting='等网络'; ProtocolWaiting='等接入方式'; RetryLater='稍后再试'; Cooldown='休息10分钟'
        PausedCredentials='账号密码错啦'; PausedBalance='余额不够'; PausedAccount='账号停用啦'; PausedDecrypt='密码解不开'; InternalError='本地出错了'
    }
    try { $state=Read-CampusState } catch { return [pscustomobject]@{Run='状态未知';Auth='状态未知';Internet='状态未知';Task='未知';Last='状态文件无法读取';Detail='请双击"03-更新账号密码"重建设置吧。';Tone='Warn'} }
    $run='NeedSetup'; if($state.Status.ContainsKey('Run')){$run=$state.Status.Run}
    if(Test-Path -LiteralPath $script:DisabledPath){$run='Disabled'} elseif(-not (Test-Path -LiteralPath $script:CredentialPath)){$run='NeedSetup'}
    $auth='Unknown'; if($state.Status.ContainsKey('Authentication')){$auth=$state.Status.Authentication}
    $internet='NotChecked'; if($state.Status.ContainsKey('Internet')){$internet=$state.Status.Internet}
    $task='没装'; try{$owned=Get-CampusOwnedTask;if($null -ne $owned){$task=[string]$owned.State}}catch{$task='任务冲突'}
    $last='还没查过'; if($state.LastCheck){try{$last=([DateTimeOffset]::Parse($state.LastCheck)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')}catch{}}
    $detail='开机后自动检查，之后每分钟一次哦~'
    if($run -in @('PausedCredentials','PausedBalance','PausedAccount','PausedDecrypt','Cooldown')){$detail=$map[$run]+'，去更新一下账号密码就能恢复啦。'} elseif($run -eq 'NeedSetup'){$detail='还没存账号密码呢，双击"01-首次设置"开始吧。'} elseif($run -eq 'Disabled'){$detail='自动认证已停用，密码还好好存着呢。'}
    $tone='Good'; if($run -in @('NeedSetup','Disabled') -or $auth -in @('Offline','Unknown') -or $internet -eq 'Unavailable'){$tone='Warn'}; if($run -in @('PausedCredentials','PausedBalance','PausedAccount','PausedDecrypt','InternalError')){$tone='Bad'}
    return [pscustomobject]@{Run=$map[$run];Auth=$map[$auth];Internet=$map[$internet];Task=$task;Last=$last;Detail=$detail;Tone=$tone}
}

function Add-CuteCard {
    param($Form,[int]$X,[int]$Y,[int]$Width,[int]$Height,[string]$Emoji,[string]$Title,[string]$Value,[string]$Hint,[Drawing.Color]$BgColor,[Drawing.Color]$ValueColor)
    $card=New-Object Windows.Forms.Panel
    $card.Location=New-Object Drawing.Point($X,$Y)
    $card.Size=New-Object Drawing.Size($Width,$Height)
    $card.BackColor=$BgColor
    $card.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $Form.Controls.Add($card)

    $emojiLabel=New-Object Windows.Forms.Label
    $emojiLabel.Text=$Emoji
    $emojiLabel.Font=New-Object Drawing.Font('Segoe UI Emoji',16)
    $emojiLabel.Location=New-Object Drawing.Point(16,14)
    $emojiLabel.Size=New-Object Drawing.Size(30,30)
    $card.Controls.Add($emojiLabel)

    $titleLabel=New-Object Windows.Forms.Label
    $titleLabel.Text=$Title
    $titleLabel.ForeColor=[Drawing.Color]::FromArgb(120,110,130)
    $titleLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $titleLabel.Location=New-Object Drawing.Point(52,18)
    $titleLabel.Size=New-Object Drawing.Size(($Width-70),20)
    $card.Controls.Add($titleLabel)

    $valueLabel=New-Object Windows.Forms.Label
    $valueLabel.Text=$Value
    $valueLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
    $valueLabel.ForeColor=$ValueColor
    $valueLabel.Location=New-Object Drawing.Point(16,50)
    $valueLabel.Size=New-Object Drawing.Size(($Width-32),26)
    $card.Controls.Add($valueLabel)

    $hintLabel=New-Object Windows.Forms.Label
    $hintLabel.Text=$Hint
    $hintLabel.ForeColor=[Drawing.Color]::FromArgb(160,150,170)
    $hintLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',8)
    $hintLabel.Location=New-Object Drawing.Point(16,($Height-24))
    $hintLabel.Size=New-Object Drawing.Size(($Width-32),16)
    $card.Controls.Add($hintLabel)
}

function Show-CampusStatus {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; [Windows.Forms.Application]::EnableVisualStyles()
    $info=Get-LocalStatusInfo
    $form=New-Object Windows.Forms.Form
    $form.Text='校园网小助手'
    $form.ClientSize=New-Object Drawing.Size(520,560)
    $form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false
    $form.MinimizeBox=$false
    $form.BackColor=[Drawing.Color]::FromArgb(250,245,252)
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)

    $header=New-Object Windows.Forms.Panel
    $header.BackColor=[Drawing.Color]::FromArgb(238,225,248)
    $header.Location=New-Object Drawing.Point(0,0)
    $header.Size=New-Object Drawing.Size(520,90)
    $form.Controls.Add($header)

    $catIcon=New-Object Windows.Forms.Label
    $catIcon.Text='🐱'
    $catIcon.Font=New-Object Drawing.Font('Segoe UI Emoji',28)
    $catIcon.Location=New-Object Drawing.Point(24,18)
    $catIcon.Size=New-Object Drawing.Size(50,50)
    $header.Controls.Add($catIcon)

    $title=New-Object Windows.Forms.Label
    $title.Text='校园网小助手'
    $title.ForeColor=[Drawing.Color]::FromArgb(90,70,110)
    $title.Font=New-Object Drawing.Font('Microsoft YaHei UI',15,[Drawing.FontStyle]::Bold)
    $title.Location=New-Object Drawing.Point(82,24)
    $title.Size=New-Object Drawing.Size(250,28)
    $header.Controls.Add($title)

    $subtitle=New-Object Windows.Forms.Label
    $subtitle.Text='帮你自动连上校园网哦~'
    $subtitle.ForeColor=[Drawing.Color]::FromArgb(150,130,170)
    $subtitle.Location=New-Object Drawing.Point(83,54)
    $subtitle.Size=New-Object Drawing.Size(250,18)
    $header.Controls.Add($subtitle)

    $badgeColor=if($info.Tone -eq 'Good'){[Drawing.Color]::FromArgb(134,230,180)}elseif($info.Tone -eq 'Bad'){[Drawing.Color]::FromArgb(255,160,170)}else{[Drawing.Color]::FromArgb(255,210,140)}
    $runBadge=New-Object Windows.Forms.Label
    $runBadge.Text=$info.Run
    $runBadge.TextAlign='MiddleCenter'
    $runBadge.ForeColor=[Drawing.Color]::FromArgb(80,60,100)
    $runBadge.BackColor=$badgeColor
    $runBadge.Location=New-Object Drawing.Point(390,30)
    $runBadge.Size=New-Object Drawing.Size(105,30)
    $runBadge.Font=New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
    $header.Controls.Add($runBadge)

    $pink=[Drawing.Color]::FromArgb(255,235,240)
    $mint=[Drawing.Color]::FromArgb(225,248,238)
    $lavender=[Drawing.Color]::FromArgb(235,230,252)
    $peach=[Drawing.Color]::FromArgb(255,240,225)

    $authColor=if($info.Auth -eq '已连上'){[Drawing.Color]::FromArgb(60,180,120)}elseif($info.Auth -eq '还没连'){[Drawing.Color]::FromArgb(230,100,120)}else{[Drawing.Color]::FromArgb(220,150,60)}
    $internetColor=if($info.Internet -eq '畅通'){[Drawing.Color]::FromArgb(60,180,120)}elseif($info.Internet -eq '不通'){[Drawing.Color]::FromArgb(230,100,120)}else{[Drawing.Color]::FromArgb(140,120,160)}

    Add-CuteCard $form 24 110 236 98 '📡' '校园网认证' $info.Auth 'Dr.COM 网关状态' $pink $authColor
    Add-CuteCard $form 268 110 236 98 '🌐' '外网探测' $info.Internet '外面的世界通不通' $mint $internetColor
    Add-CuteCard $form 24 224 236 98 '⏰' '计划任务' $info.Task '后台自动小助手' $lavender ([Drawing.Color]::FromArgb(120,100,150))
    Add-CuteCard $form 268 224 236 98 '🕐' '上次检查' $info.Last '最近一次体检时间' $peach ([Drawing.Color]::FromArgb(180,120,80))

    $detailBox=New-Object Windows.Forms.Panel
    $detailBox.BackColor=[Drawing.Color]::FromArgb(245,238,250)
    $detailBox.Location=New-Object Drawing.Point(24,340)
    $detailBox.Size=New-Object Drawing.Size(480,56)
    $form.Controls.Add($detailBox)

    $detail=New-Object Windows.Forms.Label
    $detail.Text=$info.Detail
    $detail.ForeColor=[Drawing.Color]::FromArgb(120,100,140)
    $detail.Location=New-Object Drawing.Point(16,10)
    $detail.Size=New-Object Drawing.Size(450,36)
    $detail.AutoEllipsis=$true
    $detailBox.Controls.Add($detail)

    $loginBtn=New-Object Windows.Forms.Button
    $loginBtn.Text='🔄 立即登录'
    $loginBtn.FlatStyle='Flat'
    $loginBtn.FlatAppearance.BorderSize=0
    $loginBtn.BackColor=[Drawing.Color]::FromArgb(200,170,230)
    $loginBtn.ForeColor=[Drawing.Color]::White
    $loginBtn.Location=New-Object Drawing.Point(24,420)
    $loginBtn.Size=New-Object Drawing.Size(130,40)
    $loginBtn.Font=New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold)
    $form.Controls.Add($loginBtn)

    $refreshBtn=New-Object Windows.Forms.Button
    $refreshBtn.Text='✨ 刷新状态'
    $refreshBtn.FlatStyle='Flat'
    $refreshBtn.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(210,190,230)
    $refreshBtn.BackColor=[Drawing.Color]::White
    $refreshBtn.ForeColor=[Drawing.Color]::FromArgb(120,90,150)
    $refreshBtn.Location=New-Object Drawing.Point(170,420)
    $refreshBtn.Size=New-Object Drawing.Size(110,40)
    $refreshBtn.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $form.Controls.Add($refreshBtn)

    $close=New-Object Windows.Forms.Button
    $close.Text='关闭'
    $close.DialogResult=[Windows.Forms.DialogResult]::OK
    $close.FlatStyle='Flat'
    $close.FlatAppearance.BorderSize=0
    $close.BackColor=[Drawing.Color]::FromArgb(150,130,180)
    $close.ForeColor=[Drawing.Color]::White
    $close.Location=New-Object Drawing.Point(394,420)
    $close.Size=New-Object Drawing.Size(110,40)
    $close.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $form.Controls.Add($close)
    $form.AcceptButton=$close

    $refreshBtn.Add_Click({
        $refreshBtn.Enabled=$false
        $refreshBtn.Text='检查中...'
        $form.Refresh()
        try {
            Invoke-LocalWorker -ReadOnly
            $form.Close()
        } catch {
            $refreshBtn.Enabled=$true
            $refreshBtn.Text='✨ 刷新状态'
        }
    })

    $loginBtn.Add_Click({
        $loginBtn.Enabled=$false
        $loginBtn.Text='登录中...'
        $form.Refresh()
        try {
            Invoke-LocalWorker
            $form.Close()
        } catch {
            $loginBtn.Enabled=$true
            $loginBtn.Text='🔄 立即登录'
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Show-CampusSetup {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text='校园网小助手 · 设置'
    $form.ClientSize=New-Object Drawing.Size(540,450)
    $form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false
    $form.MinimizeBox=$false
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $form.BackColor=[Drawing.Color]::FromArgb(250,245,252)

    $header=New-Object Windows.Forms.Panel
    $header.BackColor=[Drawing.Color]::FromArgb(238,225,248)
    $header.Location=New-Object Drawing.Point(0,0)
    $header.Size=New-Object Drawing.Size(540,80)
    $form.Controls.Add($header)

    $hint=New-Object Windows.Forms.Label
    $hint.Text='🐾 填一次，以后自动帮你连'
    $hint.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold)
    $hint.ForeColor=[Drawing.Color]::FromArgb(90,70,110)
    $hint.Location=New-Object Drawing.Point(28,18)
    $hint.Size=New-Object Drawing.Size(480,28)
    $header.Controls.Add($hint)

    $subHint=New-Object Windows.Forms.Label
    $subHint.Text='完整账号哦，一般是 学号@telecom 这样'
    $subHint.ForeColor=[Drawing.Color]::FromArgb(150,130,170)
    $subHint.Location=New-Object Drawing.Point(29,48)
    $subHint.Size=New-Object Drawing.Size(480,20)
    $header.Controls.Add($subHint)

    $boxes=@()
    $labels=@('完整账号','密码','再输一次密码')
    for($i=0;$i -lt 3;$i++) {
        $label=New-Object Windows.Forms.Label
        $label.Text=$labels[$i]
        $label.ForeColor=[Drawing.Color]::FromArgb(120,100,140)
        $label.Location=New-Object Drawing.Point(28,(112+$i*58))
        $label.Size=New-Object Drawing.Size(110,24)
        $form.Controls.Add($label)

        $box=New-Object Windows.Forms.TextBox
        $box.Location=New-Object Drawing.Point(140,(109+$i*58))
        $box.Size=New-Object Drawing.Size(370,28)
        $box.BorderStyle='FixedSingle'
        $box.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
        if($i -gt 0){$box.UseSystemPasswordChar=$true}
        $form.Controls.Add($box)
        $boxes+=$box
    }
    $accountBox=$boxes[0]; $passwordBox=$boxes[1]; $confirmBox=$boxes[2]
    if (Test-Path -LiteralPath $script:CredentialPath) {
        try { $existing=Get-CampusCredential; $accountBox.Text=$existing.UserName; $existing=$null } catch {}
    }

    $note=New-Object Windows.Forms.Label
    $note.Text='密码会用 Windows 加密存在本机，别人看不到的~'
    $note.ForeColor=[Drawing.Color]::FromArgb(150,130,170)
    $note.Location=New-Object Drawing.Point(28,298)
    $note.Size=New-Object Drawing.Size(480,20)
    $form.Controls.Add($note)

    $tip=New-Object Windows.Forms.Label
    $tip.Text='保存后开机自动连，之后每分钟检查一次哦'
    $tip.ForeColor=[Drawing.Color]::FromArgb(180,160,200)
    $tip.Font=New-Object Drawing.Font('Microsoft YaHei UI',8)
    $tip.Location=New-Object Drawing.Point(28,324)
    $tip.Size=New-Object Drawing.Size(480,18)
    $form.Controls.Add($tip)

    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'
    $cancel.FlatStyle='Flat'
    $cancel.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(210,190,230)
    $cancel.BackColor=[Drawing.Color]::White
    $cancel.ForeColor=[Drawing.Color]::FromArgb(120,90,150)
    $cancel.Location=New-Object Drawing.Point(300,380)
    $cancel.Size=New-Object Drawing.Size(90,36)
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $save=New-Object Windows.Forms.Button
    $save.Text='保存并启用 ✨'
    $save.FlatStyle='Flat'
    $save.FlatAppearance.BorderSize=0
    $save.BackColor=[Drawing.Color]::FromArgb(200,170,230)
    $save.ForeColor=[Drawing.Color]::White
    $save.Location=New-Object Drawing.Point(400,380)
    $save.Size=New-Object Drawing.Size(110,36)
    $form.Controls.Add($save)

    $form.AcceptButton=$save
    $form.CancelButton=$cancel

    $save.Add_Click({
        if ([string]::IsNullOrWhiteSpace($accountBox.Text) -or $accountBox.Text -match '[\r\n\t]') {
            Show-LocalMessage '请填写完整账号，例如 学号@telecom。'; return
        }
        if ($passwordBox.Text.Length -eq 0 -or $passwordBox.Text -cne $confirmBox.Text) {
            Show-LocalMessage '密码要输两次哦，而且得一样~'; return
        }
        $save.Enabled=$false; $cancel.Enabled=$false
        $lock=$null; $secret=$null; $credential=$null
        try {
            $task=Get-CampusOwnedTask
            Set-Content -LiteralPath $script:DisabledPath -Value 'disabled' -Encoding ASCII
            if($null -ne $task){Stop-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -ErrorAction SilentlyContinue}
            Stop-CampusWorker
            for($attempt=0;$attempt -lt 20;$attempt++){
                $lock=Enter-CampusLock
                if($null -ne $lock){break}
                Start-Sleep -Milliseconds 100
            }
            if($null -eq $lock){throw 'WorkerBusy'}
            $secret=ConvertTo-SecureString -String $passwordBox.Text -AsPlainText -Force
            $credential=New-Object Management.Automation.PSCredential($accountBox.Text,$secret)
            Save-CampusCredential $credential
            Register-CampusTask
            $state=New-CampusState
            Set-CampusStatus $state 'Control' 'Saved'
            Set-CampusStatus $state 'Run' 'Ready'
            Write-CampusState $state
            Remove-Item -LiteralPath $script:NoticePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:DisabledPath -Force -ErrorAction Stop
            $form.DialogResult=[Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            Show-LocalMessage "设置没能存上，程序还是停用状态。`r`n看看是不是文件夹没权限，然后再试一次吧。"
            $save.Enabled=$true; $cancel.Enabled=$true
        } finally {
            if($null -ne $lock){$lock.Dispose()}
            $passwordBox.Clear(); $confirmBox.Clear()
            if($null -ne $secret){$secret.Dispose()}
            $secret=$null; $credential=$null
        }
    })
    $result=$form.ShowDialog()
    $passwordBox.Clear(); $confirmBox.Clear()
    $form.Dispose()
    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        try { Start-ScheduledTask -TaskName $script:TaskName -TaskPath '\' } catch {}
        Show-LocalMessage "存好啦！自动运行已经开了。`r`n马上就会在后台第一次尝试认证。`r`n双击「05-查看状态」就能看到结果哦~"
    }
}

function Invoke-LocalWorker {
    param([switch]$ReadOnly)
    $lock=Enter-CampusLock
    if ($null -eq $lock) {
        if($ShowResult){Show-LocalMessage '另一次检查正在跑哦，稍等一下再看结果吧~'}
        return
    }
    $runnerFile=Join-Path $script:DataRoot 'runner.json'
    try {
        $process=Get-Process -Id $PID
        @{Pid=$PID; StartTicks=$process.StartTime.ToUniversalTime().Ticks; Sid=$script:Sid} |
            ConvertTo-Json | Set-Content -LiteralPath $runnerFile -Encoding UTF8
        $state=Read-CampusState
        Invoke-CampusCheck $state -ReadOnly:$ReadOnly
        Write-CampusState $state
    } catch {
        if($null -ne (Get-Variable state -ErrorAction SilentlyContinue) -and $null -ne $state) {
            try { Set-CampusStatus $state 'Run' 'InternalError'; Write-CampusState $state } catch {}
        }
        if($ShowResult){Show-LocalMessage '这次检查没跑完，看看状态或者重新存一下设置吧。'}
    } finally {
        Remove-Item -LiteralPath $runnerFile -Force -ErrorAction SilentlyContinue
        $lock.Dispose()
    }
    if($ShowResult){Show-LocalMessage (Get-LocalStatusText)}
}

try {
    switch($Mode) {
        'Setup' { Show-CampusSetup }
        'Update' { Show-CampusSetup }
        'Check' { Invoke-LocalWorker }
        'Probe' { Invoke-LocalWorker -ReadOnly }
        'Status' { Invoke-LocalWorker -ReadOnly; Show-CampusStatus }
        'Disable' {
            Disable-CampusTask
            $lock=Enter-CampusLock
            if($null -eq $lock){throw 'WorkerBusy'}
            try {
                $state=Read-CampusState
                Set-CampusStatus $state 'Control' 'Stopped'
                Set-CampusStatus $state 'Run' 'Disabled'
                Write-CampusState $state
            } finally { $lock.Dispose() }
            Show-LocalMessage "已经停用啦，后台任务也删了。`r`n密码还留着呢，下次想恢复的时候直接重新设置就行。"
        }
        'ClearCredentials' {
            Add-Type -AssemblyName System.Windows.Forms
            $choice=[Windows.Forms.MessageBox]::Show("这样会关掉自动登录，还会删掉存的账号密码哦。`r`n以后要用得重新输，确定要这么做吗？",
                '清除保存的密码',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
            if($choice -eq [Windows.Forms.DialogResult]::Yes) {
                Disable-CampusTask
                $lock=Enter-CampusLock
                if($null -eq $lock){throw 'WorkerBusy'}
                try {
                    foreach($file in @($script:CredentialPath,($script:CredentialPath+'.tmp'))) {
                        if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force -ErrorAction Stop}
                    }
                    Remove-Item -LiteralPath $script:NoticePath -Force -ErrorAction SilentlyContinue
                    $state=New-CampusState
                    Set-CampusStatus $state 'Control' 'Cleared'
                    Set-CampusStatus $state 'Run' 'Disabled'
                    Write-CampusState $state
                } finally { $lock.Dispose() }
                Show-LocalMessage '已经停用啦，账号密码也删干净了。'
            }
        }
    }
} catch {
    if($Mode -notin @('Check','Probe')) {
        Show-LocalMessage '操作没完成哦，看看文件夹是不是能写、有没有别的设置窗口开着，然后再试一次吧。'
    }
    exit 1
}
