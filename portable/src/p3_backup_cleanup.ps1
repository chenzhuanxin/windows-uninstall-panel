# --------------------------------------------------------------------------
# 审计日志（每次破坏性动作都留痕）
# --------------------------------------------------------------------------
function Add-AuditLog([string]$line) {
    try {
        if (-not $Script:LogDir) { return }
        $f = Join-Path $Script:LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
        [IO.File]::AppendAllText($f, ((Now-Str) + '  ' + $line + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# --------------------------------------------------------------------------
# 注册表快照 / 还原（自研 JSON 快照，不依赖 reg.exe）
# --------------------------------------------------------------------------
function Get-RegHive([string]$prefix, [switch]$Writable) {
    switch ($prefix.ToUpper()) {
        'HKLM' { return [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_LOCAL_MACHINE' { return [Microsoft.Win32.Registry]::LocalMachine }
        'HKCU' { return [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_CURRENT_USER' { return [Microsoft.Win32.Registry]::CurrentUser }
        'HKCR' { return [Microsoft.Win32.Registry]::ClassesRoot }
        'HKEY_CLASSES_ROOT' { return [Microsoft.Win32.Registry]::ClassesRoot }
        'HKU' { return [Microsoft.Win32.Registry]::Users }
        'HKEY_USERS' { return [Microsoft.Win32.Registry]::Users }
    }
    return $null
}
function Split-RegPath([string]$full) {
    if ($full -match '^(HKLM|HKCU|HKCR|HKU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_CLASSES_ROOT|HKEY_USERS)\\(.+)$') {
        return @{ hive = $Matches[1]; sub = $Matches[2] }
    }
    return $null
}
function Convert-RegNode($key, [string]$subPath, $counter, [int]$limit) {
    if ($counter.n -ge $limit) { $counter.truncated = $true; return $null }
    $counter.n = $counter.n + 1
    $vals = New-Object System.Collections.ArrayList
    try {
        foreach ($vn in $key.GetValueNames()) {
            $kn = 'String'
            try { $kn = $key.GetValueKind($vn).ToString() } catch { $kn = 'String' }
            $raw = $null
            try { $raw = $key.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $raw = $null }
            if ($raw -is [byte[]]) {
                [void]$vals.Add([pscustomobject][ordered]@{ name = $vn; kind = $kn; data = [Convert]::ToBase64String($raw) })
            } elseif ($raw -is [array]) {
                [void]$vals.Add([pscustomobject][ordered]@{ name = $vn; kind = $kn; data = @($raw) })
            } else {
                [void]$vals.Add([pscustomobject][ordered]@{ name = $vn; kind = $kn; data = $raw })
            }
        }
    } catch { }
    $subs = New-Object System.Collections.ArrayList
    try {
        foreach ($sn in $key.GetSubKeyNames()) {
            $ck = $null
            try { $ck = $key.OpenSubKey($sn) } catch { $ck = $null }
            if (-not $ck) { continue }
            $child = Convert-RegNode $ck ($subPath + '\' + $sn) $counter $limit
            try { $ck.Close() } catch { }
            if ($null -eq $child) { break }
            [void]$subs.Add($child)
        }
    } catch { }
    return [pscustomobject][ordered]@{ key = $subPath; values = @($vals); subkeys = @($subs) }
}
function Get-RegDump([string]$fullPath, [int]$limit = 20000) {
    $item = [ordered]@{ key = $fullPath; hive = ''; path = ''; tree = $null; count = 0; truncated = $false; at = (Now-Str); error = '' }
    $sp = Split-RegPath $fullPath
    if (-not $sp) {
        $item['error'] = '无法解析的注册表路径（需以 HKLM\ 或 HKCU\ 开头）'
        return [pscustomobject]$item
    }
    $hive = Get-RegHive $sp.hive
    $item['hive'] = $sp.hive.ToUpper()
    $item['path'] = $sp.sub
    $key = $null
    try { $key = $hive.OpenSubKey($sp.sub) } catch { $key = $null }
    if (-not $key) {
        $item['error'] = '键不存在或无权访问'
        return [pscustomobject]$item
    }
    $counter = @{ n = 0; truncated = $false }
    try { $item['tree'] = Convert-RegNode $key $sp.sub $counter $limit } catch { $item['error'] = $_.Exception.Message }
    try { $key.Close() } catch { }
    $item['count'] = $counter.n
    $item['truncated'] = $counter.truncated
    return [pscustomobject]$item
}
function New-RegSnapshot($keys, [string]$label, [string]$dir = '') {
    if (-not $dir) { $dir = $Script:BackupDir }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $safeLabel = ($label -replace '[^\w\-]', '_')
    $file = Join-Path $dir ('regsnap_' + $safeLabel + '_' + (Now-Tag) + '.json')
    $items = New-Object System.Collections.ArrayList
    foreach ($k in @($keys)) { [void]$items.Add((Get-RegDump $k)) }
    $payload = [ordered]@{ at = (Now-Str); label = $label; keys = @($keys); items = @($items) }
    Save-JsonFile $file $payload
    $ok = @($items | Where-Object { -not $_.error }).Count
    return @{ file = $file; ok = $ok; total = @($items).Count; label = $label; at = (Now-Str) }
}
function Restore-RegSnapshot([string]$file) {
    $restored = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    $data = Read-JsonFile $file $null
    if (-not $data) {
        [void]$failed.Add([pscustomobject]@{ key = $file; error = '快照文件无法读取' })
        return @{ restored = @(); failed = @($failed) }
    }
    foreach ($item in @($data.items)) {
        if ($item.error -or (-not $item.tree)) {
            [void]$failed.Add([pscustomobject]@{ key = [string]$item.key; error = [string]$item.error })
            continue
        }
        $hive = Get-RegHive ([string]$item.hive)
        if (-not $hive) { continue }
        Restore-RegNode $hive $item.tree $restored $failed
    }
    return @{ restored = @($restored); failed = @($failed) }
}
function Restore-RegNode($hive, $node, $restored, $failed) {
    $sub = [string]$node.key
    $key = $null
    try { $key = $hive.CreateSubKey($sub) } catch { $key = $null }
    $vFail = ''
    if ($key) {
        foreach ($v in @($node.values)) {
            try {
                $kindName = [string]$v.kind
                $val = $v.data
                switch ($kindName) {
                    'Binary' { $val = [Convert]::FromBase64String([string]$v.data) }
                    'MultiString' { $val = [string[]]@($v.data) }
                    'DWord' { $val = [int]$v.data }
                    'QWord' { $val = [int64]$v.data }
                    'None' { $val = $null }
                    default { $val = [string]$v.data }
                }
                $kind = [Microsoft.Win32.RegistryValueKind]$kindName
                $key.SetValue([string]$v.name, $val, $kind)
            } catch { $vFail = $vFail + [string]$v.name + ': ' + $_.Exception.Message + '; ' }
        }
        try { $key.Close() } catch { }
    }
    if (-not $key) {
        [void]$failed.Add([pscustomobject]@{ key = $sub; error = '无法创建/打开键' })
    } elseif ($vFail) {
        [void]$failed.Add([pscustomobject]@{ key = $sub; error = '部分值写入失败 -> ' + $vFail })
    } else {
        [void]$restored.Add($sub)
    }
    foreach ($c in @($node.subkeys)) { Restore-RegNode $hive $c $restored $failed }
}
function Get-SnapshotList {
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @(@($Script:BackupDir, 'backup'), @($Script:QuarDir, 'quarantine'))) {
        $dir = [string]$d[0]; $kind = [string]$d[1]
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $fs = @()
        try { $fs = [IO.Directory]::GetFiles($dir, 'regsnap_*.json', [IO.SearchOption]::AllDirectories) } catch { $fs = @() }
        foreach ($f in $fs) {
            $meta = Read-JsonFile $f $null
            $cnt = 0
            if ($meta -and $meta.items) { $cnt = @($meta.items).Count }
            [void]$out.Add([pscustomobject]@{ file = $f; kind = $kind
                at = $(if ($meta) { [string]$meta.at } else { '' })
                label = $(if ($meta) { [string]$meta.label } else { '' }); keys = $cnt })
        }
    }
    return @{ snapshots = @($out | Sort-Object { $_.at } -Descending) }
}

# --------------------------------------------------------------------------
# 系统备份：还原点 + 注册表卸载项快照
# --------------------------------------------------------------------------
$Script:BackupFile = ''
function Get-BackupState {
    if (-not $Script:BackupFile) { $Script:BackupFile = Join-Path $Script:BackupDir 'last_backup.json' }
    if (-not $Script:BackupState) {
        $b = Read-JsonFile $Script:BackupFile $null
        if ($b) { $Script:BackupState = $b } else { $Script:BackupState = [pscustomobject]@{ restorePoint = $false; regDir = ''; at = ''; note = '' } }
    }
    return $Script:BackupState
}
function Invoke-Backup([string]$note) {
    $info = [ordered]@{ checkpoint = 'skipped'; enableSr = 'skipped'; points = @() }
    # 1) 系统保护是否开启（未开启则尝试开启，否则无法创建还原点）
    try {
        $enableCmd = Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue
        $disabled = $false
        try {
            $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')
            if ($rk) {
                $d = $rk.GetValue('DisableSR')
                if ($null -ne $d -and [int]$d -eq 1) { $disabled = $true }
                $rk.Close()
            }
        } catch { }
        if ($disabled -and $enableCmd) {
            Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
            $info['enableSr'] = 'ok（原为关闭状态，已自动开启）'
        } elseif ($disabled) {
            $info['enableSr'] = '系统保护处于关闭状态，且当前环境不支持自动开启'
        } else {
            $info['enableSr'] = 'already-on'
        }
    } catch { $info['enableSr'] = $_.Exception.Message }
    # 2) 创建还原点
    try {
        Checkpoint-Computer -Description '完全卸载面板：卸载操作前备份' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $info['checkpoint'] = 'ok'
    } catch { $info['checkpoint'] = $_.Exception.Message }
    # 3) 已有还原点
    try {
        $pts = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 5)
        $list = New-Object System.Collections.ArrayList
        foreach ($p in $pts) { [void]$list.Add(([string]$p.Description + ' @ ' + [string]$p.CreationTime)) }
        $info['points'] = @($list)
    } catch { }
    # 4) 注册表卸载项快照（自研，内容等价于 reg export，可一键写回）
    $keys = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $snapInfo = $null
    try { $snapInfo = New-RegSnapshot $keys 'backup' } catch { $snapInfo = @{ file = ''; ok = 0; total = 0 } }
    $Script:BackupState = [pscustomobject]@{ restorePoint = ($info['checkpoint'] -eq 'ok'); regDir = $snapInfo.file
        at = (Now-Str); note = $note }
    Save-JsonFile $Script:BackupFile $Script:BackupState
    Add-AuditLog ('备份完成 | 还原点=' + $info['checkpoint'] + ' | 系统保护=' + $info['enableSr'] + ' | 快照=' + $snapInfo.file + ' (' + $snapInfo.ok + '/' + $snapInfo.total + ')')
    return [ordered]@{ ok = $true; regDir = $snapInfo.file; restorePoint = ($info['checkpoint'] -eq 'ok')
        snapshot = @{ ok = $snapInfo.ok; total = $snapInfo.total }; info = $info }
}

# --------------------------------------------------------------------------
# 残留隔离区（移动而非删除，可还原）
# --------------------------------------------------------------------------
$Script:ManifestFile = ''
function Get-Manifest {
    if (-not $Script:ManifestFile) { $Script:ManifestFile = Join-Path $Script:QuarDir 'manifest.json' }
    $m = Read-JsonFile $Script:ManifestFile $null
    if (-not $m) { return @() }
    return @($m)
}
function Save-Manifest($m) { Save-JsonFile $Script:ManifestFile @($m) }

function Invoke-Quarantine($paths, $regkeys) {
    $ts = Now-Tag
    $box = Join-Path $Script:QuarDir $ts
    New-Item -ItemType Directory -Force -Path $box | Out-Null
    $entry = [ordered]@{ batch = $ts; at = (Now-Str); files = @(); regs = @(); regSnapshot = '' }
    $files = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($p in @($paths)) {
        $i++
        if (-not ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p))) {
            [void]$files.Add([pscustomobject][ordered]@{ src = $p; dest = ''; status = 'missing'; isDir = $false; error = '' })
            continue
        }
        $base = ''
        try { $base = [IO.Path]::GetFileName((([string]$p).TrimEnd('\'))) } catch { $base = '' }
        if (-not $base) { $base = 'item_' + $i }
        $dest = Join-Path $box ((('{0:d2}' -f $i) + '_') + $base)
        try {
            Move-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop
            [void]$files.Add([pscustomobject][ordered]@{ src = $p; dest = $dest; status = 'moved'
                isDir = [IO.Directory]::Exists($dest); error = '' })
        } catch {
            [void]$files.Add([pscustomobject][ordered]@{ src = $p; dest = ''; status = 'failed'; isDir = $false; error = $_.Exception.Message })
        }
    }
    $entry['files'] = @($files)

    $regList = @($regkeys)
    if ($regList.Count -gt 0) {
        $snap = New-RegSnapshot $regList ('quarantine-' + $ts) $box
        $entry['regSnapshot'] = $snap.file
        $regsOut = New-Object System.Collections.ArrayList
        foreach ($k in $regList) {
            $status = 'FAILED'
            $sp = Split-RegPath ([string]$k)
            if ($sp) {
                $hive = Get-RegHive $sp.hive
                $exists = $false
                try { $t = $hive.OpenSubKey($sp.sub); if ($t) { $exists = $true; $t.Close() } } catch { }
                if (-not $exists) {
                    $status = 'MISSING'
                } else {
                    try { $hive.DeleteSubKeyTree($sp.sub, $false); $status = 'DELETED' } catch { $status = 'FAILED' }
                }
            }
            [void]$regsOut.Add([pscustomobject]@{ key = $k; status = $status })
        }
        $entry['regs'] = @($regsOut)
    }

    $man = New-Object System.Collections.ArrayList
    foreach ($b in (Get-Manifest)) { [void]$man.Add($b) }
    [void]$man.Add([pscustomobject]$entry)
    Save-Manifest $man
    Add-AuditLog ('隔离批次 ' + $ts + ' | 文件 移动 ' + (@($files | Where-Object { $_.status -eq 'moved' }).Count) + '/' + @($files).Count + ' | 注册表 ' + @($regList).Count + ' 项 | 快照=' + [string]$entry['regSnapshot'])
    return [ordered]@{ ok = $true; batch = $ts; entry = [pscustomobject]$entry }
}

function Restore-QuarantineItems($dests) {
    $man = Get-Manifest
    $restored = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    foreach ($d in @($dests)) {
        $hitBatch = $null; $hitFile = $null
        foreach ($b in $man) {
            foreach ($f in @($b.files)) {
                if ($f.dest -and ([string]$f.dest) -eq [string]$d) { $hitBatch = $b; $hitFile = $f }
            }
        }
        if (-not $hitFile) {
            [void]$failed.Add([pscustomobject]@{ dest = $d; error = '隔离清单中未找到该条目' })
            continue
        }
        if (-not ([IO.Directory]::Exists($d) -or [IO.File]::Exists($d))) {
            [void]$failed.Add([pscustomobject]@{ dest = $d; error = '隔离区中的该项已不存在' })
            continue
        }
        $src = [string]$hitFile.src
        try {
            $parent = ''
            try { $parent = [IO.Path]::GetDirectoryName($src) } catch { $parent = '' }
            if ($parent -and -not [IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            if ([IO.Directory]::Exists($src) -or [IO.File]::Exists($src)) {
                $src = $src + '_restored_' + (Get-Date).ToString('HHmmss')
            }
            Move-Item -LiteralPath $d -Destination $src -Force -ErrorAction Stop
            $hitFile.status = 'restored'
            [void]$restored.Add([pscustomobject]@{ src = $src; dest = $d })
        } catch {
            [void]$failed.Add([pscustomobject]@{ dest = $d; error = $_.Exception.Message })
        }
    }
    Save-Manifest $man
    Add-AuditLog ('还原隔离项 | 成功 ' + @($restored).Count + ' 失败 ' + @($failed).Count)
    return @{ restored = @($restored); failed = @($failed) }
}

function Send-ToRecycle($paths) {
    $results = New-Object System.Collections.ArrayList
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    foreach ($p in @($paths)) {
        try {
            if (-not ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p))) {
                [void]$results.Add('MISSING: ' + $p); continue
            }
            if ([IO.Directory]::Exists($p)) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            }
            [void]$results.Add('RECYCLED: ' + $p)
        } catch {
            [void]$results.Add('FAIL: ' + $p + ' :: ' + $_.Exception.Message)
        }
    }
    return @{ results = @($results) }
}

function Clear-QuarantineManifest {
    $man = Get-Manifest
    $kept = New-Object System.Collections.ArrayList
    foreach ($b in $man) {
        $files = New-Object System.Collections.ArrayList
        foreach ($f in @($b.files)) {
            $alive = $false
            if ($f.dest -and ([IO.Directory]::Exists([string]$f.dest) -or [IO.File]::Exists([string]$f.dest))) { $alive = $true }
            if ($f.status -ne 'moved' -or $alive) { [void]$files.Add($f) }
        }
        $b.files = @($files)
        $keepBatch = $false
        if (@($files).Count -gt 0) { $keepBatch = $true }
        if (@($b.regs).Count -gt 0) { $keepBatch = $true }
        if ($keepBatch) { [void]$kept.Add($b) }
    }
    Save-Manifest $kept
    return $true
}
