# --------------------------------------------------------------------------
# 体积统计
# --------------------------------------------------------------------------
function Test-Reparse([string]$p) {
    try { return (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) } catch { return $false }
}
function Get-DirSize([string]$path) {
    $res = [ordered]@{ bytes = 0; files = 0; capped = $false; missing = $false }
    if (-not $path) { $res['missing'] = $true; return $res }
    if (-not [IO.Directory]::Exists($path)) {
        if ([IO.File]::Exists($path)) {
            try { $res['bytes'] = ([IO.FileInfo]$path).Length; $res['files'] = 1 } catch { }
        } else { $res['missing'] = $true }
        return $res
    }
    $bytes = [int64]0; $files = 0; $cap = $false
    $stack = New-Object System.Collections.Stack
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        if ($files -ge 80000) { $cap = $true; break }
        $cur = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($cur)) {
                try { $bytes += ([IO.FileInfo]$f).Length; $files++ } catch { }
                if ($files -ge 80000) { $cap = $true; break }
            }
        } catch { }
        if ($cap) { break }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($cur)) {
                if (-not (Test-Reparse $d)) { $stack.Push($d) }
            }
        } catch { }
    }
    $res['bytes'] = $bytes; $res['files'] = $files; $res['capped'] = $cap
    return $res
}
function Get-SizePaths($paths) {
    $out = [ordered]@{}
    foreach ($p in @($paths)) {
        if (-not $p) { continue }
        $out[[string]$p] = Get-DirSize ([string]$p)
    }
    return $out
}

# --------------------------------------------------------------------------
# 卸载命令构造
# --------------------------------------------------------------------------
function Split-CmdLine([string]$cmd) {
    $cmd = ('' + $cmd).Trim()
    if (-not $cmd) { return @{ exe = ''; args = '' } }
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { return @{ exe = $Matches[1]; args = $Matches[2].Trim() } }
    $low = $cmd.ToLower()
    $i = $low.LastIndexOf('.exe')
    if ($i -gt 0) {
        $exe = $cmd.Substring(0, $i + 4).Trim().Trim('"')
        $args = $cmd.Substring($i + 4).Trim()
        return @{ exe = $exe; args = $args }
    }
    return @{ exe = $cmd; args = '' }
}
function Get-Operation($app, [string]$mode, [string]$overrideCmd) {
    if (-not $mode) { $mode = 'silent' }
    if ($app.kind -eq 'msi' -and $app.productCode) {
        $q = '/qn'
        if ($mode -ne 'silent') { $q = '/qb' }
        return [ordered]@{ id = $app.id; name = $app.name; kind = 'msi'; exe = 'msiexec.exe'
            args = ('/x ' + $app.productCode + ' ' + $q + ' /norestart'); package = ''
            regKey = ('' + $app.regRoot + '\' + $app.regKey); noWindow = ($mode -eq 'silent')
            cmd = ('msiexec.exe /x ' + $app.productCode + ' ' + $q + ' /norestart')
            risk = $app.risk; riskReason = $app.riskReason }
    }
    if ($app.kind -eq 'appx') {
        return [ordered]@{ id = $app.id; name = $app.name; kind = 'appx'; exe = ''; args = ''
            package = $app.productCode; regKey = ''; noWindow = $true
            cmd = ('Remove-AppxPackage -Package "' + $app.productCode + '"')
            risk = $app.risk; riskReason = $app.riskReason }
    }
    $cmdline = ''
    if ($overrideCmd) { $cmdline = $overrideCmd }
    elseif ($mode -eq 'silent') { $cmdline = [string]$app.silentCmd }
    if (-not $cmdline) {
        $cmdline = [string]$app.interactiveCmd
        if (-not $cmdline) { $cmdline = [string]$app.uninstall }
    }
    $sp = Split-CmdLine $cmdline
    return [ordered]@{ id = $app.id; name = $app.name; kind = 'exe'; exe = $sp.exe; args = $sp.args
        package = ''; regKey = ('' + $app.regRoot + '\' + $app.regKey); noWindow = ($mode -eq 'silent')
        cmd = ('"' + $sp.exe + '" ' + $sp.args).Trim()
        risk = $app.risk; riskReason = $app.riskReason }
}
function Get-PreviewSteps($ids, [string]$mode, $overrides) {
    $state = Get-AppsState
    $byId = @{}
    foreach ($a in $state.apps) { $byId[$a.id] = $a }
    $steps = New-Object System.Collections.ArrayList
    foreach ($i in @($ids)) {
        if (-not $byId.ContainsKey($i)) { continue }
        $a = $byId[$i]
        $ov = ''
        if ($overrides -and $overrides.PSObject.Properties[$i]) { $ov = [string]$overrides.PSObject.Properties[$i].Value }
        if (-not $ov -and $overrides -and ($overrides -is [hashtable]) -and $overrides.ContainsKey($i)) { $ov = [string]$overrides[$i] }
        $op = Get-Operation $a $mode $ov
        [void]$steps.Add([pscustomobject][ordered]@{ id = $a.id; name = $a.name; risk = $a.risk
            kind = $op.kind; cmd = $op.cmd; riskReason = $a.riskReason; note = [string]$a.blocker })
    }
    return $steps
}

# --------------------------------------------------------------------------
# 卸载作业（在独立运行空间中执行，主线程继续响应界面）
# --------------------------------------------------------------------------
$Script:JobWorker = @'
param([string]$InFile, [string]$OutFile)

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$job = $null
try { $job = ([IO.File]::ReadAllText($InFile, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
if (-not $job) { return }

$log = New-Object System.Collections.ArrayList
$results = New-Object System.Collections.ArrayList
$steps = @($job.steps)
$total = $steps.Count

function Save-State([string]$status) {
    $payload = [ordered]@{ status = $status; jobId = $job.jobId; mode = $job.mode
        startedAt = $job.startedAt; finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        log = @($log); results = @($results) }
    try { [IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $payload -Depth 8 -Compress), $utf8) } catch { }
}
function Add-Log([string]$line) {
    [void]$log.Add($line)
    Save-State 'running'
}
function Test-RegKey([string]$full) {
    if (-not $full) { return $false }
    try {
        if ($full -match '^(HKLM|HKEY_LOCAL_MACHINE)\\(.+)$') {
            $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Matches[2])
            if ($k) { $k.Close(); return $true } else { return $false }
        }
        if ($full -match '^(HKCU|HKEY_CURRENT_USER)\\(.+)$') {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Matches[2])
            if ($k) { $k.Close(); return $true } else { return $false }
        }
    } catch { }
    return $false
}

Save-State 'running'
Add-Log ('开始卸载 ' + $total + ' 项，模式：' + $job.mode)
$n = 0
foreach ($s in $steps) {
    $n++
    Add-Log ''
    Add-Log ('=== [' + $n + '/' + $total + '] ' + $s.name + ' ===')
    Add-Log ('方式 ' + $s.kind + ' | ' + $s.cmd)
    $ok = $false
    $code = $null
    if ($job.mode -eq 'dryrun') {
        Add-Log '（演练模式：不执行任何操作，仅校验命令生成与作业流水线）'
        $ok = $true
        [void]$results.Add([pscustomobject][ordered]@{ id = $s.id; name = $s.name; ok = $true; exit = $null })
        Save-State 'running'
        continue
    }
    if ($s.kind -eq 'appx') {
        try {
            Remove-AppxPackage -Package $s.package -ErrorAction Stop
            Add-Log 'AppX 包移除指令已执行'
            $ok = $true
        } catch {
            Add-Log ('ERROR: ' + $_.Exception.Message)
        }
        try {
            $still = Get-AppxPackage -Package $s.package -ErrorAction SilentlyContinue
            $gone = -not [bool]$still
            Add-Log ('verify: appx gone = ' + $gone)
            if ($gone) { $ok = $true }
        } catch { }
    } else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $s.exe
        $psi.Arguments = [string]$s.args
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = [bool]$s.noWindow
        $p = $null
        try { $p = [System.Diagnostics.Process]::Start($psi) } catch {
            Add-Log ('ERROR: 无法启动卸载程序（路径不存在或权限不足） -> ' + $_.Exception.Message)
        }
        if ($p) {
            Add-Log ('pid=' + $p.Id + ' 已启动，等待卸载结束…')
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $p.WaitForExit(15000)) {
                Add-Log ('  ...仍在运行 ' + [int]$sw.Elapsed.TotalSeconds + ' 秒（部分卸载向导需你在弹出的窗口中点确认）')
            }
            $sw.Stop()
            try { $code = $p.ExitCode } catch { $code = $null }
            $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            if ($null -eq $code) { Add-Log ('exit=? (耗时 ' + $sec + ' 秒)') }
            elseif ($s.kind -eq 'msi' -and ($code -eq 0 -or $code -eq 3010)) {
                Add-Log ('exit=0 (耗时 ' + $sec + ' 秒' + $(if ($code -eq 3010) { '，原始返回码 3010 表示需要重启' } else { '' }) + ')')
                $ok = $true
            } elseif ($s.kind -ne 'msi' -and $code -eq 0) {
                Add-Log ('exit=0 (耗时 ' + $sec + ' 秒)')
                $ok = $true
            } else {
                Add-Log ('exit=' + $code + ' (耗时 ' + $sec + ' 秒)')
            }
            try { $p.Dispose() } catch { }
        }
        if ($s.regKey) {
            $exists = Test-RegKey $s.regKey
            Add-Log ('verify: registry key gone = ' + (-not $exists))
            if (-not $exists) { $ok = $true }
        }
    }
    [void]$results.Add([pscustomobject][ordered]@{ id = $s.id; name = $s.name; ok = $ok; exit = $code })
    Save-State 'running'
}

$good = @($results | Where-Object { $_.ok }).Count
Add-Log ''
Add-Log ('=== 全部结束：成功 ' + $good + ' / ' + $total + ' ===')
Save-State 'done'
'@

function Start-UninstallJob($ops, [string]$mode) {
    # 硬保护：自检模式 / 演练模式下，物理上不可能执行任何卸载
    if ($Script:SelfTestMode -and $mode -ne 'dryrun') {
        Add-AuditLog ('自检模式拦截了一次真实卸载请求（mode=' + $mode + '），已强制降级为 dryrun')
        $mode = 'dryrun'
    }
    $jid = (Now-Tag) + '_' + (Get-Random -Minimum 1000 -Maximum 9999)
    $inFile = Join-Path $Script:JobsDir ($jid + '.in.json')
    $outFile = Join-Path $Script:JobsDir ($jid + '.json')
    $payload = [ordered]@{ jobId = $jid; mode = $mode; startedAt = (Now-Str); steps = @($ops) }
    Save-JsonCompact $inFile $payload
    Save-JsonCompact $outFile ([ordered]@{ status = 'running'; jobId = $jid; mode = $mode; log = @('作业已创建，正在启动…'); results = @() })
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($Script:JobWorker).AddParameter('InFile', $inFile).AddParameter('OutFile', $outFile)
        $null = $ps.BeginInvoke()
        $Script:Jobs[$jid] = $ps
    } catch {
        Save-JsonCompact $outFile ([ordered]@{ status = 'done'; jobId = $jid; log = @('ERROR: 无法启动作业 -> ' + $_.Exception.Message); results = @() })
    }
    return $jid
}
function Get-JobTail([string]$jid) {
    if (-not $jid) { return $null }
    if ($jid -notmatch '^[0-9]{8}_[0-9]{6}_[0-9]{4}$') { return $null }
    $f = Join-Path $Script:JobsDir ($jid + '.json')
    $d = Read-JsonFile $f $null
    return $d
}

# --------------------------------------------------------------------------
# 残留扫描（文件 + 注册表，只读）
# --------------------------------------------------------------------------
$Script:ExtraPaths = @{
    '微信'             = @('%APPDATA%\Tencent\WeChat', '%APPDATA%\Tencent\xwechat', '%LOCALAPPDATA%\Tencent\WeChat', '%LOCALAPPDATA%\Tencent\xwechat', '%USERPROFILE%\Documents\xwechat_files', '%USERPROFILE%\Documents\WeChat Files')
    '企业微信'         = @('%APPDATA%\Tencent\WXWork', '%LOCALAPPDATA%\Tencent\WXWork', '%USERPROFILE%\Documents\WXWork')
    '微信开发者工具'   = @('%LOCALAPPDATA%\微信开发者工具', '%APPDATA%\微信开发者工具', '%USERPROFILE%\.wechat_devtools')
    '百度网盘'         = @('%LOCALAPPDATA%\BaiduNetdisk', '%APPDATA%\Baidu\Netdisk', '%USERPROFILE%\BaiduNetdiskDownload')
    '夸克'             = @('%LOCALAPPDATA%\Quark', '%APPDATA%\Quark', '%APPDATA%\QuarkCloudDrive')
    '阿里云盘'         = @('%LOCALAPPDATA%\aDrive', '%APPDATA%\aDrive')
    '迅雷'             = @('%APPDATA%\Thunder Network', '%LOCALAPPDATA%\Thunder Network')
    '剪映专业版'       = @('%LOCALAPPDATA%\JianyingPro', '%APPDATA%\JianyingPro')
    'ToDesk'           = @('%APPDATA%\ToDesk', '%PROGRAMDATA%\ToDesk')
    'Charles 5.2'      = @('%APPDATA%\Charles')
    'WPS Office 2023 专业版' = @('%LOCALAPPDATA%\Kingsoft', '%APPDATA%\Kingsoft')
    'phpstudy集成环境' = @('%USERPROFILE%\phpstudy_pro', '%PROGRAMDATA%\phpstudy_pro')
    'Git'              = @('%USERPROFILE%\.gitconfig', '%USERPROFILE%\.git-credentials')
    'Google Chrome'    = @('%LOCALAPPDATA%\Google\Chrome')
    'Microsoft Edge'   = @('%LOCALAPPDATA%\Microsoft\Edge')
    'Mozilla Firefox (x64 zh-CN)' = @('%APPDATA%\Mozilla\Firefox', '%LOCALAPPDATA%\Mozilla\Firefox')
    'Microsoft Visual Studio Code (User)' = @('%APPDATA%\Code', '%USERPROFILE%\.vscode')
    'Microsoft OneDrive' = @('%LOCALAPPDATA%\Microsoft\OneDrive')
    'GitHub CLI'       = @('%APPDATA%\GitHub CLI', '%LOCALAPPDATA%\GitHub CLI')
    'dotnet'           = @('%PROGRAMDATA%\dotnet')
}
$Script:SkipDirs = @('microsoft', 'windows', 'packages', 'temp', 'winsxs', 'google', 'mozilla',
    'common files', 'internet explorer', 'windowsapps', 'nvidia corporation', 'intel', 'amd')

function Get-SubDirs([string]$p) {
    try { return [IO.Directory]::GetDirectories($p) } catch { return @() }
}
function Get-FileIndex {
    $idx = New-Object System.Collections.ArrayList
    $roots = New-Object System.Collections.ArrayList
    if ($env:ProgramFiles) { [void]$roots.Add(@($env:ProgramFiles, 2)) }
    if (${env:ProgramFiles(x86)}) { [void]$roots.Add(@(${env:ProgramFiles(x86)}, 2)) }
    if ($env:ProgramData) { [void]$roots.Add(@($env:ProgramData, 2)) }
    if ($env:LOCALAPPDATA) { [void]$roots.Add(@($env:LOCALAPPDATA, 2)); [void]$roots.Add(@((Join-Path $env:LOCALAPPDATA 'Programs'), 1)) }
    if ($env:APPDATA) { [void]$roots.Add(@($env:APPDATA, 2)) }
    foreach ($r in $roots) {
        $root = [string]$r[0]; $depth = [int]$r[1]
        if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
        foreach ($e1 in (Get-SubDirs $root)) {
            if (Test-Reparse $e1) { continue }
            [void]$idx.Add($e1)
            $n1 = ''
            try { $n1 = [IO.Path]::GetFileName($e1).ToLower() } catch { $n1 = '' }
            if ($depth -ge 2 -and -not ($Script:SkipDirs -contains $n1)) {
                foreach ($e2 in (Get-SubDirs $e1)) {
                    if (-not (Test-Reparse $e2)) { [void]$idx.Add($e2) }
                }
            }
        }
    }
    return $idx
}
function Get-RegIndex {
    $idx = New-Object System.Collections.ArrayList
    $bases = New-Object System.Collections.ArrayList
    try { [void]$bases.Add(@([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software'), 'HKCU\Software')) } catch { }
    try { [void]$bases.Add(@([Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE'), 'HKLM\SOFTWARE')) } catch { }
    try { [void]$bases.Add(@([Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\WOW6432Node'), 'HKLM\SOFTWARE\WOW6432Node')) } catch { }
    foreach ($b in $bases) {
        $base = $b[0]; $prefix = [string]$b[1]
        if (-not $base) { continue }
        $l1 = @()
        try { $l1 = $base.GetSubKeyNames() } catch { $l1 = @() }
        foreach ($n1 in $l1) {
            if ($idx.Count -gt 60000) { break }
            [void]$idx.Add($prefix + '\' + $n1)
            $k1 = $null
            try { $k1 = $base.OpenSubKey($n1) } catch { $k1 = $null }
            if (-not $k1) { continue }
            $l2 = @()
            try { $l2 = $k1.GetSubKeyNames() } catch { $l2 = @() }
            foreach ($n2 in $l2) {
                if ($idx.Count -gt 60000) { break }
                [void]$idx.Add($prefix + '\' + $n1 + '\' + $n2)
            }
            try { $k1.Close() } catch { }
        }
        try { $base.Close() } catch { }
    }
    return $idx
}
function Get-AllTokens($apps) {
    $out = New-Object System.Collections.ArrayList
    foreach ($a in $apps) {
        if (-not $a.uninstallable) { continue }
        foreach ($tok in @($a.tokens)) {
            $e = Get-EffLen $tok
            if ($e -ge 4) {
                [void]$out.Add([pscustomobject]@{ tok = $tok; low = $tok.ToLower(); eff = $e; name = $a.name; id = $a.id })
            }
        }
    }
    return $out
}
function Get-BestOwner([string]$baseName, $allTokens) {
    $bl = ('' + $baseName).ToLower()
    $best = $null
    foreach ($t in $allTokens) {
        if ($bl.Contains($t.low)) {
            if ($null -eq $best -or $t.eff -gt $best.eff) { $best = $t }
        }
    }
    return $best
}
function Remove-SubPaths($items) {
    $sorted = @($items | Sort-Object { $_.path.Length })
    $kept = New-Object System.Collections.ArrayList
    foreach ($it in $sorted) {
        $low = ('' + $it.path).ToLower().TrimEnd('\')
        $dup = $false
        foreach ($k in $kept) {
            $kl = ('' + $k.path).ToLower().TrimEnd('\')
            if ($low -eq $kl -or $low.StartsWith($kl + '\')) { $dup = $true; break }
        }
        if (-not $dup) { [void]$kept.Add($it) }
    }
    return $kept
}

function Get-Leftover($ids) {
    $state = Get-AppsState
    $byId = @{}
    foreach ($a in $state.apps) { $byId[$a.id] = $a }
    $targets = New-Object System.Collections.ArrayList
    foreach ($i in @($ids)) { if ($byId.ContainsKey($i)) { [void]$targets.Add($byId[$i]) } }
    $allTok = Get-AllTokens $state.apps
    $fileIndex = Get-FileIndex
    $regIndex = Get-RegIndex
    $out = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        $toks = @(@($t.tokens) | Where-Object { (Get-EffLen $_) -ge 4 })
        $files = New-Object System.Collections.ArrayList
        $regs = New-Object System.Collections.ArrayList
        $seen = New-Object System.Collections.Generic.HashSet[string]

        foreach ($p in (('' + $t.installLoc) -replace '"', '') -split ';') {
            $p = $p.Trim()
            if ($p -and [IO.Directory]::Exists($p) -and $seen.Add($p.ToLower())) {
                [void]$files.Add([pscustomobject]@{ path = $p; why = '注册表中记录的安装目录'; conf = 'high' })
            }
        }
        foreach ($path in $fileIndex) {
            $base = ''
            try { $base = [IO.Path]::GetFileName($path) } catch { continue }
            $blow = $base.ToLower()
            $hit = ''; $hitEff = 0
            foreach ($tok in $toks) {
                $e = Get-EffLen $tok
                if ($blow.Contains($tok.ToLower())) {
                    if ($e -gt $hitEff) { $hit = $tok; $hitEff = $e }
                }
            }
            if (-not $hit) { continue }
            $owner = Get-BestOwner $base $allTok
            $conf = 'mid'; $why = '目录名匹配「' + $hit + '」'
            if ($owner -and $owner.id -ne $t.id -and $owner.eff -gt $hitEff) {
                $conf = 'low'; $why = '目录名匹配「' + $hit + '」，但更像属于「' + $owner.name + '」'
            } elseif ($owner -and $owner.id -eq $t.id -and $owner.eff -gt $hitEff) {
                $conf = 'high'; $why = '目录名匹配「' + $owner.tok + '」'
            }
            if ($seen.Add($path.ToLower())) {
                [void]$files.Add([pscustomobject]@{ path = $path; why = $why; conf = $conf })
            }
        }
        if ($Script:ExtraPaths.ContainsKey($t.name)) {
            foreach ($ep in $Script:ExtraPaths[$t.name]) {
                $real = ''
                try { $real = [Environment]::ExpandEnvironmentVariables($ep) } catch { continue }
                if ($real -and ([IO.Directory]::Exists($real) -or [IO.File]::Exists($real)) -and $seen.Add($real.ToLower())) {
                    $kindTxt = '目录'
                    if ([IO.File]::Exists($real)) { $kindTxt = '文件' }
                    [void]$files.Add([pscustomobject]@{ path = $real; why = '已知' + $t.name + '的' + $kindTxt + '残留位置'; conf = 'high' })
                }
            }
        }
        $seenReg = New-Object System.Collections.Generic.HashSet[string]
        foreach ($full in $regIndex) {
            $leaf = $full
            $i2 = $full.LastIndexOf('\')
            if ($i2 -ge 0) { $leaf = $full.Substring($i2 + 1) }
            $leafLow = $leaf.ToLower()
            $hit = ''; $hitEff = 0
            foreach ($tok in $toks) {
                $e = Get-EffLen $tok
                if ($leafLow.Contains($tok.ToLower())) {
                    if ($e -gt $hitEff) { $hit = $tok; $hitEff = $e }
                }
            }
            if (-not $hit) { continue }
            $owner = Get-BestOwner $leaf $allTok
            $conf = 'mid'; $why = '键名匹配「' + $hit + '」'
            if ($owner -and $owner.id -ne $t.id -and $owner.eff -gt $hitEff) {
                $conf = 'low'; $why = '键名匹配「' + $hit + '」，但更像属于「' + $owner.name + '」'
            }
            if ($seenReg.Add($full.ToLower())) {
                [void]$regs.Add([pscustomobject]@{ path = $full; why = $why; conf = $conf })
            }
        }
        [void]$out.Add([pscustomobject][ordered]@{
            id = $t.id; name = $t.name; tokens = @($t.tokens)
            files = @(Remove-SubPaths $files); regs = @(Remove-SubPaths $regs)
            installLoc = [string]$t.installLoc
        })
    }
    return [ordered]@{ items = $out; scannedAt = (Now-Str) }
}
