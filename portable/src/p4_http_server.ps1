# --------------------------------------------------------------------------
# 内嵌界面（单文件，无需任何外部资源）
# --------------------------------------------------------------------------
$Script:HTML = @'
@@HTML@@
'@

# --------------------------------------------------------------------------
# HTTP 服务
# --------------------------------------------------------------------------
function Write-Bytes($ctx, [int]$code, [byte[]]$bytes, [string]$ctype) {
    try {
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = $ctype
        $ctx.Response.ContentLength64 = $bytes.Length
        try { $ctx.Response.Headers.Add('Cache-Control', 'no-store') } catch { }
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { } finally {
        try { $ctx.Response.Close() } catch { }
    }
}
function Send-Json($ctx, [int]$code, $obj) {
    $json = '{"error":"序列化失败"}'
    try { $json = ConvertTo-Json -InputObject $obj -Depth 14 -Compress } catch { }
    Write-Bytes $ctx $code ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}
function Send-Error($ctx, [int]$code, [string]$msg) { Send-Json $ctx $code ([ordered]@{ error = $msg }) }
function Read-Payload($ctx) {
    $body = ''
    try {
        $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd(); $sr.Close()
    } catch { $body = '' }
    $h = @{}
    if ($body) {
        try {
            $o = $body | ConvertFrom-Json
            if ($o -is [hashtable]) { return $o }
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { }
    }
    return $h
}

function Invoke-Route($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $isGet = ($req.HttpMethod -eq 'GET')

    if ($isGet -and ($path -eq '/' -or $path -eq '/index.html')) {
        Write-Bytes $ctx 200 ([Text.Encoding]::UTF8.GetBytes($Script:HTML)) 'text/html; charset=utf-8'
        return
    }
    if ($path -eq '/api/quit') {
        Send-Json $ctx 200 ([ordered]@{ ok = $true })
        $Script:Running = $false
        return
    }
    if ($isGet -and $path -eq '/api/state') {
        $d = Get-AppsState
        $bs = Get-BackupState
        $out = [ordered]@{ env = $d.env; apps = $d.apps; stats = $d.stats; loadedAt = $d.loadedAt
            elevated = $Script:IsAdmin
            backup = [ordered]@{ at = [string]$bs.at; restorePoint = [bool]$bs.restorePoint; regDir = [string]$bs.regDir } }
        Send-Json $ctx 200 $out
        return
    }
    if ($isGet -and $path -eq '/api/snapshots') {
        Send-Json $ctx 200 (Get-SnapshotList); return
    }
    if ($isGet -and $path -eq '/api/quarantine') {
        Send-Json $ctx 200 ([ordered]@{ manifest = @(Get-Manifest); dir = $Script:QuarDir }); return
    }
    if ($isGet -and $path -eq '/api/job') {
        $jid = ''
        try { $jid = [string]$req.QueryString['id'] } catch { $jid = '' }
        $tail = Get-JobTail $jid
        if (-not $tail) { Send-Error $ctx 404 '未找到该作业'; return }
        Send-Json $ctx 200 $tail
        return
    }
    if ($isGet) { Send-Error $ctx 404 '未找到该接口'; return }

    $p = Read-Payload $ctx

    if ($path -eq '/api/rescan') {
        $Script:AppCache = $null
        Send-Json $ctx 200 ([ordered]@{ ok = $true }); return
    }
    if ($path -eq '/api/backup') {
        Send-Json $ctx 200 (Invoke-Backup ([string]$p['note'])); return
    }
    if ($path -eq '/api/preview') {
        $ids = @($p['ids'])
        if (-not $ids) { $ids = @() }
        $mode = [string]$p['mode']; if (-not $mode) { $mode = 'silent' }
        Send-Json $ctx 200 ([ordered]@{ steps = @(Get-PreviewSteps $ids $mode $p['overrides']) })
        return
    }
    if ($path -eq '/api/uninstall') {
        if ([string]$p['confirm'] -ne 'UNINSTALL') { Send-Error $ctx 400 '缺少确认令牌'; return }
        $ids = @($p['ids'])
        if ($ids.Count -gt 10) { Send-Error $ctx 400 '单批最多 10 项，请分批执行（安全护栏）'; return }
        if ($ids.Count -eq 0) { Send-Error $ctx 400 '未选择任何软件'; return }
        $bs = Get-BackupState
        if (-not [string]$bs.at) { Send-Error $ctx 400 '请先执行「系统备份」（创建还原点并快照注册表）'; return }
        $state = Get-AppsState
        $byId = @{}
        foreach ($a in $state.apps) { $byId[$a.id] = $a }
        $mode = [string]$p['mode']; if (-not $mode) { $mode = 'silent' }
        $overrides = $p['overrides']
        $ops = New-Object System.Collections.ArrayList
        $blocked = New-Object System.Collections.ArrayList
        foreach ($i in $ids) {
            if (-not $byId.ContainsKey($i)) { continue }
            $a = $byId[$i]
            if (-not $a.uninstallable) {
                [void]$blocked.Add([pscustomobject]@{ name = $a.name; why = $a.riskReason }); continue
            }
            $ov = ''
            if ($overrides -and $overrides.PSObject.Properties[$i]) { $ov = [string]$overrides.PSObject.Properties[$i].Value }
            [void]$ops.Add((Get-Operation $a $mode $ov))
        }
        if ($ops.Count -eq 0) { Send-Error $ctx 400 '所选项目均不可自动卸载'; return }
        $snapKeys = New-Object System.Collections.ArrayList
        foreach ($i in $ids) {
            if (-not $byId.ContainsKey($i)) { continue }
            $a = $byId[$i]
            if ($a.source -eq 'appx' -or $a.kind -eq 'appx') { continue }
            $k = ([string]$a.regRoot + '\' + [string]$a.regKey)
            if ($k -match '^(HKLM|HKCU)\\') { [void]$snapKeys.Add($k) }
        }
        if ($snapKeys.Count -gt 0) {
            try { [void](New-RegSnapshot @($snapKeys) 'pre-uninstall') } catch { }
        }
        $jid = Start-UninstallJob @($ops) $mode
        Send-Json $ctx 200 ([ordered]@{ ok = $true; jobId = $jid; count = $ops.Count; blocked = @($blocked) })
        return
    }
    if ($path -eq '/api/snapshot') {
        $keys = @($p['keys'])
        $label = [string]$p['label']; if (-not $label) { $label = 'manual' }
        Send-Json $ctx 200 (New-RegSnapshot $keys $label)
        return
    }
    if ($path -eq '/api/reg-restore') {
        $done = New-Object System.Collections.ArrayList
        $failed = New-Object System.Collections.ArrayList
        foreach ($f in @($p['files'])) {
            $full = ''
            try { $full = [IO.Path]::GetFullPath([string]$f) } catch { $full = [string]$f }
            $okDir = $true
            try {
                $inBackup = $full.StartsWith([IO.Path]::GetFullPath($Script:BackupDir), [StringComparison]::OrdinalIgnoreCase)
                $inQuar = $full.StartsWith([IO.Path]::GetFullPath($Script:QuarDir), [StringComparison]::OrdinalIgnoreCase)
                if (-not ($inBackup -or $inQuar)) { $okDir = $false }
            } catch { $okDir = $false }
            if (-not $okDir) {
                [void]$failed.Add([pscustomobject]@{ file = [string]$f; error = '只允许还原本工具自己生成的快照' }); continue
            }
            $r = Restore-RegSnapshot $full
            foreach ($x in @($r.restored)) { [void]$done.Add($x) }
            foreach ($x in @($r.failed)) { [void]$failed.Add($x) }
        }
        Send-Json $ctx 200 ([ordered]@{ restored = @($done); failed = @($failed) })
        return
    }
    if ($path -eq '/api/leftover') {
        Send-Json $ctx 200 (Get-Leftover @($p['ids'])); return
    }
    if ($path -eq '/api/size') {
        Send-Json $ctx 200 ([ordered]@{ sizes = @(Get-SizePaths @($p['paths'])) }); return
    }
    if ($path -eq '/api/open') {
        $target = [string]$p['path']
        if (-not ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target))) {
            Send-Error $ctx 404 ('路径不存在：' + $target); return
        }
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"') } catch { }
        Send-Json $ctx 200 ([ordered]@{ ok = $true }); return
    }
    if ($path -eq '/api/quarantine') {
        Send-Json $ctx 200 (Invoke-Quarantine @($p['paths']) @($p['regkeys'])); return
    }
    if ($path -eq '/api/restore') {
        Send-Json $ctx 200 (Restore-QuarantineItems @($p['dests'])); return
    }
    if ($path -eq '/api/purge') {
        Send-Json $ctx 200 (Send-ToRecycle @($p['paths'])); return
    }
    if ($path -eq '/api/quarantine/cleanup') {
        Send-Json $ctx 200 ([ordered]@{ ok = (Clear-QuarantineManifest) }); return
    }
    Send-Error $ctx 404 '未找到该接口'
}

# --------------------------------------------------------------------------
# 自检：完整跑一遍「界面 -> 接口 -> 引擎 -> 可还原」链路，不卸载任何真实软件
# --------------------------------------------------------------------------
$Script:SelfTestCode = @'
param([string]$Base, [string]$OutFile)
$lines = New-Object System.Collections.ArrayList
$utf8 = New-Object System.Text.UTF8Encoding($false)
function T($s) { [void]$lines.Add([string]$s) }
function Flush { try { [IO.File]::WriteAllText($OutFile, ($lines -join "`r`n"), $utf8) } catch { } }
function HttpGet($p) {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Encoding = [Text.Encoding]::UTF8
    try { return $wc.DownloadString($Base + $p) } finally { $wc.Dispose() }
}
function HttpPost($p, $obj) {
    $body = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('Content-Type', 'application/json')
    try { return $wc.UploadString($Base + $p, 'POST', $body) } finally { $wc.Dispose() }
}
function ExpectError($p, $obj, $wantCode) {
    try {
        $null = HttpPost $p $obj
        return 'FAIL 未按预期拒绝（服务端居然接受了）'
    } catch {
        $ex = $_.Exception
        $guard = 0
        while ($ex -and (-not $ex.Response) -and $ex.InnerException -and $guard -lt 6) { $ex = $ex.InnerException; $guard++ }
        if ($ex -and $ex.Response) {
            $code = [int]$ex.Response.StatusCode
            if ($code -eq $wantCode) { return 'PASS 已按预期拒绝（HTTP ' + $code + '）' }
            return 'FAIL 返回码不符：' + $code
        }
        return 'FAIL 异常：' + $_.Exception.Message
    }
}
$testKey = 'HKCU\Software\_WBPanelSelfTest'
$qKey = 'HKCU\Software\_WBQTest'
try {
    T '================ 便携版面板 自检 ================'
    T ('时间 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    T ''
    T '[1] 静态页面'
    try {
        $html = HttpGet '/'
        $ok = ($html -like '*完全卸载面板*') -and ($html -like '*api/state*')
        T ('  ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + ' 首页 HTML ' + $html.Length + ' 字节')
    } catch { T ('  FAIL 首页取不到：' + $_.Exception.Message) }
    Flush

    T ''
    T '[2] /api/state 软件清单'
    $state = $null
    try {
        $state = (HttpGet '/api/state') | ConvertFrom-Json
        $n = @($state.apps).Count
        $st = $state.stats
        T ('  ' + $(if ($n -gt 0) { 'PASS' } else { 'FAIL' }) + ' 软件总数 ' + $n + '（桌面 ' + $st.desktop + ' / 商店 ' + $st.store + '）')
        T ('  统计: 可卸载 ' + $st.uninstallable + '，安全 ' + $st.safe + '，谨慎 ' + $st.caution + '，高风险 ' + $st.danger + '，系统组件 ' + $st.system)
        T ('  主机 ' + $state.env.machine + ' | ' + $state.env.os + ' | 管理员 ' + $state.elevated + ' | 可用 ' + $st.freeGB + ' GB')
        $first = @($state.apps)[0]
        T ('  字段检查: ' + $(if ($first.name -and $first.id -and $first.risk) { 'PASS' } else { 'FAIL' }) + ' 样例「' + $first.name + '」kind=' + $first.kind + ' risk=' + $first.risk)
        $a1 = @($state.apps | Where-Object { $_.kind -ne 'appx' -and $_.uninstallable })[0]
        $a2 = @($state.apps | Where-Object { $_.kind -eq 'appx' -and $_.uninstallable })[0]
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[3] /api/size 体积统计'
    try {
        $win = $env:SystemRoot
        $r = (HttpPost '/api/size' @{ paths = @($win) }) | ConvertFrom-Json
        $b = $r.sizes.$win
        T ('  ' + $(if ($b -and $b.bytes -gt 0) { 'PASS' } else { 'FAIL' }) + ' Windows 目录 ' + [math]::Round($b.bytes / 1MB, 1) + ' MB / ' + $b.files + ' 个文件')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[4] /api/preview 卸载命令预览'
    try {
        $ids = @()
        if ($a1) { $ids += $a1.id }
        if ($a2) { $ids += $a2.id }
        $r = (HttpPost '/api/preview' @{ ids = $ids; mode = 'silent'; overrides = @{} }) | ConvertFrom-Json
        foreach ($s in @($r.steps)) { T ('  ' + $s.name + ' [' + $s.kind + '] -> ' + $s.cmd) }
        $r2 = (HttpPost '/api/preview' @{ ids = $ids; mode = 'interactive'; overrides = @{} }) | ConvertFrom-Json
        T ('  ' + $(if (@($r.steps).Count -eq $ids.Count) { 'PASS' } else { 'FAIL' }) + ' 共生成 ' + @($r.steps).Count + ' 条命令；交互模式样例：' + @($r2.steps)[0].cmd)
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[5] 系统备份（创建还原点 + 注册表卸载项快照）'
    try {
        $bk = (HttpPost '/api/backup' @{ note = 'selftest' }) | ConvertFrom-Json
        T ('  还原点 : ' + [string]$bk.info.checkpoint)
        T ('  系统保护: ' + [string]$bk.info.enableSr)
        T ('  快照   : ' + [string]$bk.regDir)
        T ('  快照键数: ' + $bk.snapshot.ok + ' / ' + $bk.snapshot.total + ' 个键（含全部子键与值）')
        T ('  ' + $(if ($bk.snapshot.total -gt 0) { 'PASS' } else { 'FAIL' }) + ' 备份链路可用')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[6] 卸载安全护栏（此处必须被拒绝，且不执行任何卸载）'
    try {
        if ($a1) {
            T ('  ' + (ExpectError '/api/uninstall' @{ ids = @($a1.id); mode = 'silent' } 400) + ' 缺少确认令牌')
        }
        T ('  ' + (ExpectError '/api/uninstall' @{ ids = @('__wb_not_a_real_app__'); mode = 'silent'; confirm = 'UNINSTALL' } 400) + ' 无效/不可卸载项被拦截')
        $many = @()
        for ($i = 0; $i -lt 12; $i++) { $many += ('fake-' + $i) }
        T ('  ' + (ExpectError '/api/uninstall' @{ ids = $many; mode = 'silent'; confirm = 'UNINSTALL' } 400) + ' 单批上限 10 项')
        T ('  说明：自检模式已强制降级为演练，即使误发卸载请求也不会真正执行')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[7] 卸载作业流水线（演练模式：完整走流程，但不执行任何卸载）'
    try {
        $ids = @()
        if ($a1) { $ids += $a1.id }
        if ($a2) { $ids += $a2.id }
        $job = (HttpPost '/api/uninstall' @{ ids = $ids; mode = 'dryrun'; confirm = 'UNINSTALL' }) | ConvertFrom-Json
        T ('  作业已创建 ' + $job.jobId + '（' + $job.count + ' 项，被拦截 ' + @($job.blocked).Count + ' 项）')
        $done = $false; $tail = $null; $loops = 0
        while (-not $done -and $loops -lt 80) {
            Start-Sleep -Milliseconds 400
            $loops++
            $tail = (HttpGet ('/api/job?id=' + $job.jobId)) | ConvertFrom-Json
            if ($tail.status -eq 'done') { $done = $true }
        }
        T ('  作业状态 ' + $tail.status + ' | 结果 ' + @($tail.results).Count + ' 条 | 日志 ' + @($tail.log).Count + ' 行')
        foreach ($ln in (@($tail.log) | Select-Object -Last 7)) { T ('    | ' + $ln) }
        $allOk = (@($tail.results) | Where-Object { -not $_.ok }).Count -eq 0
        T ('  ' + $(if ($done -and @($tail.results).Count -eq $job.count -and $allOk) { 'PASS' } else { 'FAIL' }) + ' 作业进度轮询 / 日志 / 结果结构全部正常')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[8] 注册表快照 / 还原往返（5 种值类型 + 2 层子键）'
    try {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\_WBPanelSelfTest')
        $rk.SetValue('s', '中文值-a', 'String')
        $rk.SetValue('d', 123456, 'DWord')
        $rk.SetValue('q', [int64]9876543210, 'QWord')
        $rk.SetValue('m', [string[]]@('第一行', 'second'), 'MultiString')
        $rk.SetValue('b', [byte[]]@(1, 2, 3, 250), 'Binary')
        $rk.SetValue('e', '%TEMP%\expand', 'ExpandString')
        $c = $rk.CreateSubKey('sub1')
        $c.SetValue('x', 'deep', 'String')
        $c2 = $c.CreateSubKey('sub2')
        $c2.SetValue('y', 7, 'DWord')
        $c2.Close(); $c.Close(); $rk.Close()
        $snap = (HttpPost '/api/snapshot' @{ keys = @($testKey); label = 'selftest' }) | ConvertFrom-Json
        T ('  快照文件 ' + $snap.file + '（键数 ' + $snap.ok + '/' + $snap.total + '）')
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\_WBPanelSelfTest')
        $gone = -not [bool]([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\_WBPanelSelfTest'))
        T ('  删除测试键: ' + $(if ($gone) { 'OK' } else { 'FAIL' }))
        $rest = (HttpPost '/api/reg-restore' @{ files = @($snap.file) }) | ConvertFrom-Json
        T ('  写回注册表: 成功 ' + @($rest.restored).Count + ' 个键，失败 ' + @($rest.failed).Count + ' 个')
        $chk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\_WBPanelSelfTest')
        $vals = @{}
        if ($chk) {
            foreach ($vn in $chk.GetValueNames()) { $vals[$vn] = $chk.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            $sub = $chk.OpenSubKey('sub1')
            $deep2 = $null
            if ($sub) { $s2 = $sub.OpenSubKey('sub2'); if ($s2) { $deep2 = $s2.GetValue('y') } }
            $chk.Close()
        }
        $ok = $chk -and $vals['s'] -eq '中文值-a' -and $vals['d'] -eq 123456 -and $vals['q'] -eq 9876543210
        if ($ok) { $ok = ((@($vals['m']) -join '|') -eq '第一行|second') -and ((@($vals['b'])[3]) -eq 250) }
        if ($ok) { $ok = ($deep2 -eq 7) }
        T ('  校验: ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + ' 值类型与子键全部一致')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[9] 残留隔离 -> 还原 往返（用临时目录做试验，不碰真实软件）'
    try {
        $tmp = Join-Path $env:TEMP '_wb_quarantine_test'
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Set-Content -Path (Join-Path $tmp 'a.txt') -Value 'hello' -Encoding UTF8
        $qk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\_WBQTest')
        $qk.SetValue('v', 'keep-me', 'String'); $qk.Close()
        $q = (HttpPost '/api/quarantine' @{ paths = @($tmp); regkeys = @($qKey) }) | ConvertFrom-Json
        $ent = $q.entry
        $moved = @($ent.files)[0].status
        $regSt = @($ent.regs)[0].status
        T ('  隔离结果: 文件 ' + $moved + '，注册表 ' + $regSt + '，快照 ' + $ent.regSnapshot)
        $tmpGone = -not (Test-Path $tmp)
        $regGone = -not [bool]([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\_WBQTest'))
        T ('  原位置已清空: 目录 ' + $tmpGone + ' / 注册表 ' + $regGone)
        $dest = [string]@($ent.files)[0].dest
        $rs = (HttpPost '/api/restore' @{ dests = @($dest) }) | ConvertFrom-Json
        T ('  文件还原: 成功 ' + @($rs.restored).Count + '，失败 ' + @($rs.failed).Count)
        $rr = (HttpPost '/api/reg-restore' @{ files = @($ent.regSnapshot) }) | ConvertFrom-Json
        T ('  注册表还原: 成功 ' + @($rr.restored).Count + '，失败 ' + @($rr.failed).Count)
        $backFile = Test-Path (Join-Path $tmp 'a.txt')
        $rk2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\_WBQTest')
        $backReg = $false
        if ($rk2) { $backReg = ([string]$rk2.GetValue('v') -eq 'keep-me'); $rk2.Close() }
        T ('  校验: ' + $(if ($backFile -and $backReg) { 'PASS' } else { 'FAIL' }) + ' 文件已回到原位 ' + $backFile + ' / 注册表值已恢复 ' + $backReg)
        $null = HttpPost '/api/quarantine/cleanup' @{}
        $man = (HttpGet '/api/quarantine') | ConvertFrom-Json
        T ('  隔离清单条目数: ' + @($man.manifest).Count)
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\_WBQTest') } catch { }
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[10] /api/leftover 残留扫描'
    try {
        $ids = @()
        if ($a1) { $ids += $a1.id }
        $r = (HttpPost '/api/leftover' @{ ids = $ids }) | ConvertFrom-Json
        $it = @($r.items)[0]
        T ('  软件「' + $it.name + '」令牌 ' + (@($it.tokens) -join ', '))
        T ('  文件候选 ' + @($it.files).Count + ' 项 / 注册表候选 ' + @($it.regs).Count + ' 项')
        foreach ($f in (@($it.files) | Select-Object -First 4)) { T ('    [F][' + $f.conf + '] ' + $f.path + '  << ' + $f.why) }
        foreach ($g in (@($it.regs) | Select-Object -First 4)) { T ('    [R][' + $g.conf + '] ' + $g.path + '  << ' + $g.why) }
        T ('  ' + $(if (@($r.items).Count -gt 0) { 'PASS' } else { 'FAIL' }) + ' 残留扫描返回结构正常')
    } catch { T ('  FAIL ' + $_.Exception.Message) }
    Flush

    T ''
    T '[11] /api/snapshots 快照列表'
    try {
        $s = (HttpGet '/api/snapshots') | ConvertFrom-Json
        T ('  PASS 共 ' + @($s.snapshots).Count + ' 个快照')
    } catch { T ('  FAIL ' + $_.Exception.Message) }

    T ''
    T '[12] 关闭面板服务'
    try { $null = HttpPost '/api/quit' @{}; T '  PASS 已发送退出指令' } catch { T ('  FAIL ' + $_.Exception.Message) }
    T ''
    T '================ 自检结束 ================'
} catch {
    T ('严重错误: ' + $_.Exception.Message)
} finally {
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\_WBPanelSelfTest') } catch { }
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\_WBQTest') } catch { }
    Flush
}
'@

# --------------------------------------------------------------------------
# 启动
# --------------------------------------------------------------------------
function Start-Panel {
    if ($Script:SelfTestMode) {
        Write-Host ''
        Write-Host '  [自检模式] 引擎已强制降级为「演练」：本次运行物理上不会执行任何卸载或删除。' -ForegroundColor Yellow
    }
    if (-not $Script:IsAdmin) {
        Write-Host ''
        Write-Host '  [提示] 当前不是管理员权限：软件清单与残留扫描照常可用，' -ForegroundColor Yellow
        Write-Host '         但「卸载」和「深度清理」会因权限不足而失败。' -ForegroundColor Yellow
        Write-Host '         建议改用「启动面板.bat」启动（会自动请求管理员权限）。' -ForegroundColor Yellow
        Write-Host ''
    }
    $Script:Port = Get-FreePort $Port
    $url = 'http://127.0.0.1:' + $Script:Port + '/'

    try {
        $Script:Listener = New-Object System.Net.HttpListener
        $Script:Listener.Prefixes.Add($url)
        $Script:Listener.Start()
    } catch {
        Write-Host ('启动本地服务失败：' + $_.Exception.Message) -ForegroundColor Red
        return
    }

    $info = [ordered]@{ port = $Script:Port; url = $url; elevated = $Script:IsAdmin
        pid = $PID; startedAt = (Now-Str); workDir = $Script:WorkDir
        version = $Script:VERSION; psVersion = $PSVersionTable.PSVersion.ToString() }
    Save-JsonFile (Join-Path $Script:WorkDir 'panel.info.json') $info

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '     完全卸载面板 · 便携版 v' -NoNewline -ForegroundColor Cyan
    Write-Host $Script:VERSION -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ('   面板地址 : ' + $url) -ForegroundColor White
    Write-Host ('   运行模式 : ' + $(if ($Script:IsAdmin) { '管理员（可深度卸载 + 残留清理）' } else { '普通用户（部分功能受限）' })) -ForegroundColor White
    Write-Host ('   数据目录 : ' + $Script:WorkDir) -ForegroundColor Gray
    Write-Host ('   PowerShell: ' + $PSVersionTable.PSVersion.ToString() + '   端口: ' + $Script:Port) -ForegroundColor Gray
    Write-Host ''
    Write-Host '   关闭这个窗口（或按 Ctrl+C）即可停止面板。' -ForegroundColor Gray
    Write-Host ''

    if ($SelfTest) {
        $testOut = Join-Path $Script:WorkDir 'selftest.txt'
        $rs = [powershell]::Create()
        [void]$rs.AddScript($Script:SelfTestCode).AddParameter('Base', $url).AddParameter('OutFile', $testOut)
        $null = $rs.BeginInvoke()
        Write-Host '   [自检模式] 正在通过 HTTP 接口跑完整链路验证，不会卸载任何软件…' -ForegroundColor Yellow
        Write-Host ''
    } elseif (-not $NoBrowser) {
        try { Start-Process $url } catch { }
    }

    $Script:Running = $true
    try {
        while ($Script:Running -and $Script:Listener.IsListening) {
            $ctx = $null
            try { $ctx = $Script:Listener.GetContext() } catch { break }
            if (-not $ctx) { break }
            try { Invoke-Route $ctx } catch {
                try { Send-Error $ctx 500 ('处理请求出错：' + $_.Exception.Message) } catch { }
            }
        }
    } finally {
        try { $Script:Listener.Stop(); $Script:Listener.Close() } catch { }
        Write-Host '  面板已停止。' -ForegroundColor Green
    }
}

$Script:Running = $false
if (-not $WorkDir) { $WorkDir = Join-Path $env:LOCALAPPDATA 'UninstallPanel' }
$Script:WorkDir = $WorkDir
$Script:JobsDir = Join-Path $WorkDir 'jobs'
$Script:QuarDir = Join-Path $WorkDir 'quarantine'
$Script:BackupDir = Join-Path $WorkDir 'backups'
$Script:LogDir = Join-Path $WorkDir 'logs'
foreach ($d in @($Script:WorkDir, $Script:JobsDir, $Script:QuarDir, $Script:BackupDir, $Script:LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$Script:Jobs = @{}
$Script:IsAdmin = Test-IsAdmin
$Script:SelfTestMode = [bool]$SelfTest
$null = Get-BackupState

if (-not $Script:IsAdmin -and -not $NoElevate -and -not $SelfTest) {
    Write-Host ''
    Write-Host '  需要管理员权限才能深度卸载与清理残留，正在请求提权…' -ForegroundColor Yellow
    if (Invoke-SelfElevate) {
        Write-Host '  已在新的管理员窗口中启动面板，本窗口可以关闭。' -ForegroundColor Green
        Start-Sleep -Seconds 2
        exit 0
    }
    Write-Host '  提权未成功（可能被取消），将以当前权限继续运行。' -ForegroundColor Yellow
}

Start-Panel
