#Requires -Version 3.0
<#
    ============================================================
      完全卸载面板 · 便携版（Windows 通用 / 零外部依赖）
    ============================================================
    · 只用 Windows 自带的 PowerShell，不需要 Python、不需要 Node
    · 拿到任意一台 Windows 10 / 11 上都能直接跑
    · 引擎 + 界面在同一个文件里，界面是内嵌的本地网页
    · 所有破坏性动作都遵循：预览 -> 备份 -> 二次确认 -> 可还原

    用法：
      1) 双击同目录的「启动面板.bat」（会自动请求管理员权限）
      2) 或在 PowerShell 中： powershell -ExecutionPolicy Bypass -File .\UninstallPanel.ps1
    自检（不卸载任何东西，只验证引擎与界面链路）：
      powershell -ExecutionPolicy Bypass -File .\UninstallPanel.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$WorkDir = '',
    [switch]$SelfTest,
    [switch]$NoBrowser,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Script:AppName = '完全卸载面板'
$Script:VERSION = '1.0-portable'
$Script:IsAdmin = $false
$Script:AppCache = $null
$Script:BackupState = $null
$Script:ScriptPath = $PSCommandPath
if (-not $Script:ScriptPath) { try { $Script:ScriptPath = $MyInvocation.MyCommand.Path } catch { } }

# --------------------------------------------------------------------------
# 基础工具
# --------------------------------------------------------------------------
function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-TextFile([string]$Path) {
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    } catch { return $null }
}
function Read-JsonFile([string]$Path, $Default = $null) {
    try {
        $t = Read-TextFile $Path
        if (-not $t) { return $Default }
        return ($t | ConvertFrom-Json)
    } catch { return $Default }
}
function Save-JsonFile([string]$Path, $Obj) {
    Write-Utf8 $Path (ConvertTo-Json -InputObject $Obj -Depth 14)
}
function Save-JsonCompact([string]$Path, $Obj) {
    Write-Utf8 $Path (ConvertTo-Json -InputObject $Obj -Depth 14 -Compress)
}
function Now-Str { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
function Now-Tag { return (Get-Date).ToString('yyyyMMdd_HHmmss') }
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Get-FreePort([int]$start) {
    if ($start -le 0) { $start = 8791 }
    for ($p = $start; $p -lt ($start + 60); $p++) {
        $l = $null
        try {
            $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
            $l.Start(); $l.Stop()
            return $p
        } catch { if ($l) { try { $l.Stop() } catch { } } }
    }
    return $start
}
function Invoke-SelfElevate {
    if (-not $Script:ScriptPath) { return $false }
    try {
        $psExe = Join-Path $PSHOME 'powershell.exe'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script:ScriptPath + '"'))
        if ($Script:WorkDir) { $argList += @('-WorkDir', ('"' + $Script:WorkDir + '"')) }
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs
        return $true
    } catch { return $false }
}

# --------------------------------------------------------------------------
# 软件清单：注册表 Uninstall + Store(AppX)
# --------------------------------------------------------------------------
function Get-RegistryApps {
    $out = New-Object System.Collections.ArrayList
    $roots = @(
        @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = '64-bit'; RegRoot = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = '32-bit'; RegRoot = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'User'; Arch = '64-bit'; RegRoot = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    foreach ($r in $roots) {
        $base = $null
        try { $base = $r.Hive.OpenSubKey($r.Sub) } catch { $base = $null }
        if (-not $base) { continue }
        $subNames = @()
        try { $subNames = $base.GetSubKeyNames() } catch { $subNames = @() }
        foreach ($kn in $subNames) {
            $k = $null
            try { $k = $base.OpenSubKey($kn) } catch { $k = $null }
            if (-not $k) { continue }
            try {
                $name = [string]$k.GetValue('DisplayName')
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $uninstall = [string]$k.GetValue('UninstallString')
                $quiet = [string]$k.GetValue('QuietUninstallString')
                $hasU = -not [string]::IsNullOrWhiteSpace($uninstall)
                $hasQ = -not [string]::IsNullOrWhiteSpace($quiet)
                $kind = 'unknown'; $productCode = ''; $uninstallExe = ''
                if ($kn -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                    $kind = 'msi'; $productCode = $kn
                } elseif ($uninstall -match 'MsiExec(\.exe)?') {
                    $kind = 'msi'
                    if ($uninstall -match '\{[0-9A-Fa-f\-]{36}\}') { $productCode = $Matches[0] }
                } elseif ($uninstall -match '^\s*"([^"]+\.exe)"') {
                    $kind = 'exe'; $uninstallExe = $Matches[1]
                } elseif ($uninstall -match '^\s*([^\s]+\.exe)') {
                    $kind = 'exe'; $uninstallExe = $Matches[1]
                }
                if ($kind -eq 'unknown' -and $uninstall -match '\.exe') {
                    $ix = $uninstall.ToLower().LastIndexOf('.exe')
                    if ($ix -gt 0) {
                        $kind = 'exe'
                        $uninstallExe = $uninstall.Substring(0, $ix + 4).Trim().Trim('"')
                    }
                }
                $scRaw = $k.GetValue('SystemComponent')
                $sysComp = $false
                if ($null -ne $scRaw) { try { $sysComp = ([int]$scRaw -eq 1) } catch { $sysComp = $false } }
                $relType = [string]$k.GetValue('ReleaseType')
                $isUpdate = $false
                if ($k.GetValue('ParentKeyName') -or $k.GetValue('ParentDisplayName') -or ($relType -match 'Update|Hotfix|Security Update|ServicePack')) { $isUpdate = $true }
                $blocker = ''
                if (-not ($hasU -or $hasQ)) { $kind = 'none'; $blocker = 'no_uninstall_string' }
                elseif ($sysComp) { $blocker = 'system_component' }
                elseif ($isUpdate) { $blocker = 'is_update' }
                $sizeKB = 0
                try { if ($k.GetValue('EstimatedSize')) { $sizeKB = [int]$k.GetValue('EstimatedSize') } } catch { $sizeKB = 0 }
                $item = [ordered]@{
                    id             = ($r.RegRoot + '\' + $kn)
                    regKey         = $kn
                    name           = $name
                    version        = [string]$k.GetValue('DisplayVersion')
                    publisher      = [string]$k.GetValue('Publisher')
                    installDate    = [string]$k.GetValue('InstallDate')
                    sizeKB         = $sizeKB
                    installLoc     = [string]$k.GetValue('InstallLocation')
                    scope          = $r.Scope
                    arch           = $r.Arch
                    regRoot        = $r.RegRoot
                    uninstall      = $uninstall
                    quietUninstall = $quiet
                    kind           = $kind
                    productCode    = $productCode
                    uninstallExe   = $uninstallExe
                    systemComponent = $sysComp
                    isUpdate       = $isUpdate
                    uninstallable  = (($hasU -or $hasQ) -and -not $sysComp)
                    blocker        = $blocker
                    source         = 'registry'
                    displayIcon    = [string]$k.GetValue('DisplayIcon')
                }
                [void]$out.Add([pscustomobject]$item)
            } catch { } finally { try { $k.Close() } catch { } }
        }
        try { $base.Close() } catch { }
    }
    return $out
}

function Get-AppxApps {
    $out = New-Object System.Collections.ArrayList
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return $out }
    $pkgs = @()
    try { $pkgs = Get-AppxPackage -ErrorAction SilentlyContinue } catch { $pkgs = @() }
    foreach ($p in $pkgs) {
        try {
            if ($p.IsFramework -or $p.IsResourcePackage) { continue }
            $dn = ''
            try {
                $dp = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\' + $p.PackageFullName + '\App'
                $v = Get-ItemProperty -Path $dp -ErrorAction SilentlyContinue
                if ($v -and $v.DisplayName) { $dn = [string]$v.DisplayName }
            } catch { }
            $blocker = ''
            if ($p.NonRemovable) { $blocker = 'appx_non_removable' }
            if ($p.SignatureKind -eq 'System') { $blocker = 'appx_system' }
            $item = [ordered]@{
                id              = 'appx:' + $p.PackageFullName
                regKey          = $p.PackageFullName
                name            = $p.Name
                displayName     = $dn
                version         = [string]$p.Version
                publisher       = [string]$p.Publisher
                installDate     = ''
                sizeKB          = 0
                installLoc      = [string]$p.InstallLocation
                scope           = 'User'
                arch            = 'AppX'
                regRoot         = 'AppX'
                uninstall       = 'Remove-AppxPackage -Package "' + $p.PackageFullName + '"'
                quietUninstall  = ''
                kind            = 'appx'
                productCode     = $p.PackageFullName
                uninstallExe    = ''
                systemComponent = [bool]$p.NonRemovable
                isUpdate        = $false
                uninstallable   = ((-not $p.NonRemovable) -and ($p.SignatureKind -ne 'System'))
                blocker         = $blocker
                source          = 'appx'
                displayIcon     = ''
            }
            [void]$out.Add([pscustomobject]$item)
        } catch { }
    }
    return $out
}

# --------------------------------------------------------------------------
# 风险分级 / 残留匹配令牌
# --------------------------------------------------------------------------
$Script:DangerRules = @(
    @('redistributable|microsoft visual c\+\+', 'VC++ 运行库：大量已安装软件的底层依赖，卸载后这些程序会直接启动失败。'),
    @('\.net (framework|runtime|host)', '.NET 运行时：系统与众多应用的框架依赖。'),
    @('^microsoft edge$|^microsoft edge ', 'Edge 浏览器已与系统深度集成，其内核同时为 WebView2 组件供能，卸载可能影响其他应用内嵌网页。'),
    @('webview2', 'WebView2 运行时：大量应用内嵌浏览器用它渲染界面。'),
    @('nvidia|图形驱动程序|graphics driver|display driver', '显卡驱动：卸载会造成显示分辨率异常、性能严重下降，需立刻重装。'),
    @('windows software development kit|windows sdk', 'Windows SDK：编译与调试工具链的基础组件。'),
    @('update health tools', 'Windows 更新健康工具：系统自带维护组件。'),
    @('visual studio installer|visual studio 生成工具|visual studio build tools', 'VS 安装器 / 生成工具：统管多个开发组件，卸载会牵连整套工具链。'),
    @('tools for office', 'VSTO 运行时：Office 加载项的依赖。'),
    @('iis url 重写|application request routing', 'IIS 服务器模块：本地 Web 服务组件。'),
    @('usbdk', 'UsbDk 驱动：虚拟化 / 云电脑 USB 重定向依赖，卸载后相关功能失效。'),
    @('python launcher|^python 3\.\d+', 'Python 运行时 / 启动器：依赖 Python 的脚本与工具会失效。'),
    @('printservice|scan to|hp laserjet|打印机', '打印机 / 扫描仪驱动：卸载后设备无法使用。'),
    @('microsoft onedrive', 'OneDrive 与系统账户、资源管理器深度集成。'),
    @('^node\.js', 'Node.js 运行时：依赖它的前端工具链会失效。'),
    @('microsoft visual studio', 'Visual Studio 系列：开发环境主体。'),
    @('microsoft update', 'Windows 更新相关组件。'),
    @('antivirus|security center|defender', '安全软件：卸载后系统处于无防护状态。'),
    @('chipset|intel\(r\) management engine|serial io|bluetooth 驱动', '主板 / 芯片组驱动：卸载可能造成硬件工作异常。')
)
$Script:CautionRules = @(
    @('微信|wechat|wecom|企业微信', '含聊天记录、图片、文件缓存与登录状态，卸载后历史消息可能无法恢复。'),
    @('wps office|kingsoft', '含文档模板、云同步配置、最近打开记录。'),
    @('phpstudy|phpstudy_pro', '含 MySQL / Apache / Nginx 数据目录，卸载可能带走本地数据库与网站文件，务必先备份 www 与 data 目录。'),
    @('^git$|^git ', '含全局配置 .gitconfig、凭据管理器与 SSH 配置。'),
    @('chrome|firefox|edge|浏览器', '含书签、保存的密码、扩展与浏览历史；卸载时若勾选删除浏览数据将不可恢复。'),
    @('charles|fiddler|wireshark|抓包', '含已安装的抓包根证书与代理配置，卸载后需手动清理残留证书。'),
    @('todesk|向日葵|rustdesk|远控|teamviewer|anydesk', '含设备授权与远程连接凭据，卸载后需重新授权。'),
    @('网盘|netdisk|aliyun|quark|夸克|云盘|云电脑|onedrive|dropbox', '含本地同步缓存与账号登录态，缓存体积通常远大于程序中显示的占用。'),
    @('输入法|ime|sogou|baidu input', '含个人词库与自定义短语。'),
    @('github cli|gh cli', '含 GitHub 登录凭据（keyring）。'),
    @('剪映|美图|豆包|千问|photoshop|premiere|illustrator|obs', '含用户作品缓存、素材库与账号数据。'),
    @('迅雷|xunlei|thunder|qbittorrent|utorrent|bitcomet', '含下载任务记录、离线空间缓存与登录态。'),
    @('文华|东方财富|期货|交易|同花顺|通达信|券商|行情', '含自选股 / 行情配置、交易账号登录信息与本地数据。'),
    @('建设银行|工商银行|网银|安全组件|数字证书|ukey', '含网银数字证书与安全控件，卸载后需重新申请证书。'),
    @('steam|epic games|游戏|game|wegame', '含游戏存档、云同步进度与账号数据。'),
    @('visual studio code|sublime|jetbrains|pycharm|intellij|notepad\+\+', '含编辑器配置、插件与最近项目记录。'),
    @('docker|virtualbox|vmware|wsl|虚拟机', '含本地镜像、虚拟机磁盘与容器数据，体积巨大且不可再生。'),
    @('mysql|postgres|sqlite|mongodb|redis|数据库', '可能含本地数据库实例与数据目录，卸载前务必备份。'),
    @('驱动|driver|realtek|logitech|罗技|雷蛇|razer', '含外设配置文件与宏定义。')
)
$Script:VendorAlias = @(
    @('tencent', @('Tencent', '腾讯')),
    @('baidu', @('Baidu', '百度')),
    @('kingsoft', @('Kingsoft', '金山', 'WPS')),
    @('alibaba', @('Alibaba', '阿里', 'Taobao', 'aliyun')),
    @('bytedance', @('ByteDance', '字节', 'Doubao', '豆包')),
    @('xunlei', @('Xunlei', '迅雷', 'Thunder')),
    @('sogou', @('Sogou', '搜狗')),
    @('360', @('360', 'Qihoo', '奇虎')),
    @('meitu', @('Meitu', '美图')),
    @('todesk', @('ToDesk', 'YouQu')),
    @('eastmoney', @('东方财富', 'EastMoney')),
    @('nvidia', @('NVIDIA')),
    @('mozilla', @('Mozilla', 'Firefox')),
    @('google', @('Google', 'Chrome')),
    @('python', @('Python')),
    @('nodejs', @('Node.js', 'nodejs')),
    @('git', @('Git')),
    @('dingtalk', @('DingTalk', '钉钉')),
    @('hp', @('HP', 'Hewlett')),
    @('xiaomi', @('Xiaomi', '小米')),
    @('jianying', @('JianyingPro', '剪映'))
)
$Script:GenericTokens = @(
    'microsoft', 'corporation', 'corp', 'inc', 'ltd', 'co', 'limited', 'software', 'technology',
    'technologies', 'company', 'group', 'the', 'and', 'for', 'windows', 'win32', 'x64', 'x86',
    'edition', 'version', 'professional', 'pro', 'free', 'setup', 'installer', 'update', 'tool',
    'tools', 'utility', 'helper', 'service', 'agent', 'runtime', 'libraries', 'library', 'center',
    'user', 'module', 'modules', 'addon', 'add', 'redistributable', 'x', 'bit', 'info',
    'online', 'network', 'tech', 'system', 'systems', 'data', 'file', 'files',
    'holding', 'shenzhen', 'beijing', 'shanghai', 'guangzhou', 'china',
    'application', 'applications', 'app', 'apps', 'client', 'desktop', 'web', 'core', 'bin',
    'current', 'program', 'programs', 'browser', 'main', 'launcher', 'support', 'resources',
    'assets', 'lib', 'libs', 'plugin', 'plugins', 'extension', 'extensions', 'cache', 'config',
    'settings', 'docs', 'source', 'build', 'release', 'stable', 'beta', 'portable',
    'server', 'binaries', 'package', 'packages', 'content', 'public', 'static', 'share',
    '有限公司', '科技', '网络', '技术', '信息', '软件', '股份', '中心', '集团', '深圳', '北京', '上海',
    '广州', '专业版', '集成环境', '开发', '版本', '安全', '有限', '工具', '浏览器', '助手', '客户端',
    '模拟版', '实盘交易', '安全组件'
)

function Get-RiskInfo([string]$name, [string]$publisher) {
    $hay = ('' + $name + ' ' + $publisher)
    foreach ($r in $Script:DangerRules) {
        if ($hay -match $r[0]) { return @{ risk = 'danger'; why = $r[1] } }
    }
    foreach ($r in $Script:CautionRules) {
        if ($hay -match $r[0]) { return @{ risk = 'caution'; why = $r[1] } }
    }
    return @{ risk = 'safe'; why = '未发现系统依赖或用户数据风险，可正常卸载。' }
}

function Get-EffLen([string]$t) {
    $n = 0
    foreach ($ch in $t.ToCharArray()) {
        $c = [int][char]$ch
        if ($c -ge 0x4E00 -and $c -le 0x9FFF) { $n += 2 } else { $n += 1 }
    }
    return $n
}

function Get-TokenList([string]$name, [string]$publisher, [string]$installLoc) {
    $toks = New-Object System.Collections.Generic.HashSet[string]
    $clean = ('' + $name)
    $clean = $clean -replace '[\(（][^)）]*[)）]', ' '
    $clean = $clean -replace '\b\d+(\.\d+)+\b', ' '
    $clean = $clean -replace '\bv?\d+\.\d+.*$', ' '
    $parts = $clean -split '[\s\-_/\\,，、。\.\+:：\|]+'
    foreach ($t in $parts) {
        $t = ('' + $t).Trim().Trim('.').Trim()
        if ($t.Length -lt 2) { continue }
        if ($Script:GenericTokens -contains $t.ToLower()) { continue }
        if ($t -match '^[\d\.\-\+]+$') { continue }
        if ($t -match '[\u4e00-\u9fff]') {
            if ($t.Length -ge 2) { [void]$toks.Add($t) }
        } elseif ($t.Length -ge 3) { [void]$toks.Add($t) }
    }
    $pubLow = ('' + $publisher).ToLower()
    $nameLow = ('' + $name).ToLower()
    foreach ($va in $Script:VendorAlias) {
        $hit = $false
        if ($pubLow.Contains($va[0]) -or $nameLow.Contains($va[0])) { $hit = $true }
        foreach ($a in $va[1]) { if ($pubLow.Contains($a.ToLower()) -or $nameLow.Contains($a.ToLower())) { $hit = $true } }
        if ($hit) { foreach ($a in $va[1]) { if (-not $Script:GenericTokens.Contains($a.ToLower())) { [void]$toks.Add($a) } } }
    }
    foreach ($p in (('' + $installLoc) -split ';')) {
        $p = $p.Trim().Trim('"')
        if (-not $p) { continue }
        $b = ''
        try { $b = [IO.Path]::GetFileName($p.TrimEnd('\', '/')) } catch { $b = '' }
        if ($b -and $b.Length -ge 3 -and -not $Script:GenericTokens.Contains($b.ToLower())) { [void]$toks.Add($b) }
    }
    $arr = @($toks)
    [array]::Sort($arr, [StringComparer]::OrdinalIgnoreCase)
    return $arr
}

# --------------------------------------------------------------------------
# 汇总状态（供面板 /api/state 使用）
# --------------------------------------------------------------------------
function Get-AppsState {
    param([switch]$Refresh)
    if ($Script:AppCache -and -not $Refresh) { return $Script:AppCache }
    $reg = @(Get-RegistryApps)
    $appx = @(Get-AppxApps)
    $apps = New-Object System.Collections.ArrayList

    foreach ($r in $reg) {
        $ri = Get-RiskInfo $r.name $r.publisher
        $silentCmd = ''; $interactiveCmd = ''
        if ($r.kind -eq 'msi' -and $r.productCode) {
            $silentCmd = 'msiexec.exe /x ' + $r.productCode + ' /qn /norestart'
            $interactiveCmd = 'msiexec.exe /x ' + $r.productCode + ' /qb /norestart'
        } elseif ($r.kind -eq 'exe' -and ($r.uninstall -or $r.quietUninstall)) {
            $silentCmd = $r.quietUninstall
            $interactiveCmd = $r.uninstall
            if (-not $interactiveCmd) { $interactiveCmd = $r.quietUninstall }
            if (-not $silentCmd) {
                $b = ''
                try { $b = [IO.Path]::GetFileName([string]$r.uninstallExe).ToLower() } catch { $b = '' }
                if ($b.StartsWith('unins')) { $silentCmd = $r.uninstall + ' /VERYSILENT /NORESTART' }
                elseif ($b.StartsWith('uninst') -or $b.StartsWith('uninstall')) { $silentCmd = $r.uninstall + ' /S' }
            }
        }
        $o = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o['risk'] = $ri.risk
        $o['riskReason'] = $ri.why
        $o['silentCmd'] = $silentCmd
        $o['interactiveCmd'] = $interactiveCmd
        $o['tokens'] = Get-TokenList $r.name $r.publisher $r.installLoc
        $o['category'] = 'desktop'
        [void]$apps.Add([pscustomobject]$o)
    }

    foreach ($a in $appx) {
        $label = $a.displayName
        if (-not $label) { $label = $a.name }
        $ri = Get-RiskInfo $label $a.publisher
        $why = $ri.why
        $risk = $ri.risk
        if (-not $a.uninstallable) {
            $risk = 'danger'
            $why = '系统内置组件（NonRemovable），Windows 不允许卸载。'
        } elseif ($risk -eq 'safe' -and ($label -match 'store|商店|skype|画图|照片|计算器|terminal|记事本|notepad|截图|snipping|media player|相机|camera|地图|maps|天气|weather|邮件|mail|日历|calendar|人脉|people|反馈|feedback|tips|你的手机|your phone|手机连接|xbox|音乐|groove|时钟|闹钟|录音|voice|3d|mixed reality|office hub|getting started|solitaire|zune')) {
            $why = '系统预装应用，可安全移除（不影响系统运行，需要时可在商店重新安装）。'
        }
        $o = [ordered]@{}
        foreach ($p in $a.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o['name'] = $label
        $o['risk'] = $risk
        $o['riskReason'] = $why
        $o['silentCmd'] = $a.uninstall
        $o['interactiveCmd'] = $a.uninstall
        $o['tokens'] = Get-TokenList $label $a.publisher $a.installLoc
        $o['category'] = 'store'
        [void]$apps.Add([pscustomobject]$o)
    }

    $uninst = @($apps | Where-Object { $_.uninstallable })
    $stats = [ordered]@{
        total         = $apps.Count
        desktop       = @($apps | Where-Object { $_.category -eq 'desktop' }).Count
        store         = @($apps | Where-Object { $_.category -eq 'store' }).Count
        uninstallable = $uninst.Count
        safe          = @($uninst | Where-Object { $_.risk -eq 'safe' }).Count
        caution       = @($uninst | Where-Object { $_.risk -eq 'caution' }).Count
        danger        = @($uninst | Where-Object { $_.risk -eq 'danger' }).Count
        system        = @($apps | Where-Object { -not $_.uninstallable }).Count
        freeGB        = 0
    }
    try {
        $d = New-Object System.IO.DriveInfo($env:SystemDrive)
        $stats['freeGB'] = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
    } catch { $stats['freeGB'] = 0 }

    $osName = 'Windows'
    $osBuild = ''
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cv) {
            $osName = [string]$cv.ProductName
            $osBuild = [string]$cv.CurrentBuild
            if ($cv.DisplayVersion) { $osBuild = $osBuild + '.' + [string]$cv.DisplayVersion }
        }
    } catch { }
    $is64 = $false
    try { $is64 = [Environment]::Is64BitOperatingSystem } catch { $is64 = $false }
    $envInfo = [ordered]@{
        machine    = $env:COMPUTERNAME
        user       = $env:USERNAME
        os         = ($osName + ' | Build ' + $osBuild + ' | ' + $(if ($is64) { '64 位' } else { '32 位' }))
        workDir    = $Script:WorkDir
        psVersion  = $PSVersionTable.PSVersion.ToString()
        scannedAt  = (Now-Str)
    }
    $Script:AppCache = [ordered]@{ env = $envInfo; apps = $apps; stats = $stats; loadedAt = (Now-Str) }
    return $Script:AppCache
}

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

# --------------------------------------------------------------------------
# 内嵌界面（单文件，无需任何外部资源）
# --------------------------------------------------------------------------
$Script:HTML = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>完全卸载面板</title>
<style>
  :root{
    --bg:#f5f7fa; --panel:#ffffff; --panel-2:#fbfcfe; --line:#e3e8ef; --line-2:#eef1f6;
    --text:#1f2733; --text-2:#5b6675; --text-3:#8b95a5;
    --accent:#2563eb; --accent-soft:#eaf0ff;
    --safe:#0f7b4f; --safe-bg:#e8f6ef; --safe-line:#bfe6d4;
    --warn:#a35a00; --warn-bg:#fff4e3; --warn-line:#f5ddb4;
    --dang:#b42318; --dang-bg:#fdecea; --dang-line:#f6cdc8;
    --radius:10px; --shadow:0 1px 2px rgba(16,24,40,.05),0 6px 18px rgba(16,24,40,.06);
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{
    margin:0; background:var(--bg); color:var(--text);
    font:13px/1.55 "Segoe UI","Microsoft YaHei","PingFang SC",system-ui,-apple-system,sans-serif;
    -webkit-font-smoothing:antialiased;
  }
  button{font:inherit;cursor:pointer}
  input,select,textarea{font:inherit}
  ::-webkit-scrollbar{width:10px;height:10px}
  ::-webkit-scrollbar-thumb{background:#ccd4e0;border-radius:6px;border:2px solid var(--bg)}
  ::-webkit-scrollbar-thumb:hover{background:#b4bfcf}

  /* ---------- header ---------- */
  header{
    background:var(--panel); border-bottom:1px solid var(--line);
    padding:14px 22px; display:flex; align-items:center; gap:18px; flex-wrap:wrap;
    position:sticky; top:0; z-index:30;
  }
  .brand{display:flex;align-items:center;gap:10px;font-size:16px;font-weight:650;letter-spacing:.2px}
  .brand .dot{width:9px;height:9px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
  .env{display:flex;gap:8px;flex-wrap:wrap;margin-left:auto}
  .chip{
    display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;
    background:var(--panel-2);border:1px solid var(--line);color:var(--text-2);font-size:12px;white-space:nowrap;
  }
  .chip b{color:var(--text);font-weight:600}
  .chip.ok{background:var(--safe-bg);border-color:var(--safe-line);color:var(--safe)}

  /* ---------- stats ---------- */
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;padding:16px 22px 4px}
  .stat{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:12px 14px;box-shadow:var(--shadow)}
  .stat .k{font-size:12px;color:var(--text-3)}
  .stat .v{font-size:21px;font-weight:650;margin-top:3px;letter-spacing:.3px}
  .stat .v small{font-size:12px;font-weight:500;color:var(--text-3);margin-left:3px}

  /* ---------- tabs ---------- */
  .tabs{display:flex;gap:4px;padding:14px 22px 0}
  .tab{
    padding:8px 15px;border-radius:8px 8px 0 0;border:1px solid transparent;border-bottom:none;
    background:transparent;color:var(--text-2);font-weight:560;
  }
  .tab.active{background:var(--panel);border-color:var(--line);color:var(--accent);box-shadow:0 -1px 0 var(--accent) inset}
  .tab .n{font-size:11px;background:var(--accent-soft);color:var(--accent);border-radius:999px;padding:1px 6px;margin-left:6px}

  /* ---------- shell ---------- */
  .shell{padding:0 22px 120px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:0 var(--radius) var(--radius) var(--radius);box-shadow:var(--shadow);overflow:hidden}

  /* ---------- toolbar ---------- */
  .toolbar{display:flex;gap:10px;align-items:center;padding:12px 14px;border-bottom:1px solid var(--line-2);flex-wrap:wrap;background:var(--panel-2)}
  .search{position:relative;flex:1;min-width:200px;max-width:340px}
  .search input{width:100%;padding:7px 11px 7px 30px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--text);outline:none}
  .search input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
  .search svg{position:absolute;left:9px;top:7px;color:var(--text-3)}
  .filters{display:flex;gap:6px;flex-wrap:wrap}
  .f{padding:5px 11px;border-radius:999px;border:1px solid var(--line);background:var(--panel);color:var(--text-2);font-size:12px}
  .f:hover{border-color:#c8d2e0}
  .f.active{background:var(--accent);border-color:var(--accent);color:#fff}
  .f .n{opacity:.65;margin-left:4px;font-size:11px}
  .spacer{flex:1}
  .btn{padding:7px 13px;border-radius:8px;border:1px solid var(--line);background:var(--panel);color:var(--text);font-weight:520;white-space:nowrap}
  .btn:hover{border-color:#c8d2e0;background:var(--panel-2)}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn.primary:hover{background:#1d4fd8}
  .btn.danger{background:var(--dang);border-color:var(--dang);color:#fff}
  .btn.danger:hover{background:#96190f}
  .btn.ghost{border-color:transparent;background:transparent;color:var(--text-2)}
  .btn.ghost:hover{background:var(--panel-2);color:var(--text)}
  .btn.sm{padding:4px 9px;font-size:12px;border-radius:7px}

  /* ---------- table ---------- */
  table{width:100%;border-collapse:separate;border-spacing:0}
  thead th{
    position:sticky;top:0;background:var(--panel-2);z-index:5;
    text-align:left;font-weight:600;font-size:12px;color:var(--text-3);
    padding:9px 12px;border-bottom:1px solid var(--line);white-space:nowrap;user-select:none;
  }
  thead th.sortable{cursor:pointer}
  thead th.sortable:hover{color:var(--accent)}
  tbody td{padding:9px 12px;border-bottom:1px solid var(--line-2);vertical-align:middle}
  tbody tr:hover{background:var(--panel-2)}
  tbody tr.sel{background:var(--accent-soft)}
  tbody tr.disabled{opacity:.5}
  .nm{font-weight:560;color:var(--text);display:flex;align-items:center;gap:7px;flex-wrap:wrap}
  .ver{color:var(--text-3);font-size:12px}
  .pub{color:var(--text-2);font-size:12px;max-width:230px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .tag{display:inline-block;padding:1px 7px;border-radius:6px;font-size:11px;font-weight:560;border:1px solid var(--line);background:var(--panel-2);color:var(--text-2)}
  .tag.safe{background:var(--safe-bg);border-color:var(--safe-line);color:var(--safe)}
  .tag.caution{background:var(--warn-bg);border-color:var(--warn-line);color:var(--warn)}
  .tag.danger{background:var(--dang-bg);border-color:var(--dang-line);color:var(--dang)}
  .tag.store{background:#eef2ff;border-color:#d5ddfb;color:#3b4fd8}
  .tag.appx{background:#f3ecfd;border-color:#e0d3f7;color:#6b3fa8}
  .tag.msi{background:#e9f4fd;border-color:#cfe6f8;color:#0a5c95}
  .tag.exe{background:#eef7f1;border-color:#d3ebdc;color:#0f7b4f}
  input[type=checkbox]{width:15px;height:15px;accent-color:var(--accent);cursor:pointer;vertical-align:-2px}
  input[type=checkbox]:disabled{cursor:not-allowed}

  /* ---------- bottom bar ---------- */
  .actionbar{
    position:fixed;left:0;right:0;bottom:0;z-index:40;background:rgba(255,255,255,.94);
    backdrop-filter:blur(8px);border-top:1px solid var(--line);
    padding:11px 22px;display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  }
  .actionbar .sel{font-weight:600}
  .actionbar .sum{color:var(--text-3);font-size:12px}

  /* ---------- drawer ---------- */
  .drawer{
    position:fixed;top:0;right:0;bottom:0;width:430px;max-width:92vw;background:var(--panel);
    border-left:1px solid var(--line);box-shadow:-12px 0 32px rgba(16,24,40,.10);
    transform:translateX(102%);transition:transform .22s ease;z-index:60;display:flex;flex-direction:column;
  }
  .drawer.open{transform:none}
  .drawer .dh{padding:15px 18px;border-bottom:1px solid var(--line);display:flex;align-items:flex-start;gap:10px}
  .drawer .dh h3{margin:0;font-size:15px;font-weight:650;line-height:1.35}
  .drawer .db{padding:16px 18px;overflow:auto;flex:1}
  .kv{display:grid;grid-template-columns:88px 1fr;gap:6px 10px;margin-bottom:14px}
  .kv .k{color:var(--text-3);font-size:12px}
  .kv .v{color:var(--text);word-break:break-all;font-size:12px}
  .sect{margin:16px 0 7px;font-size:12px;font-weight:650;color:var(--text-2);letter-spacing:.3px;display:flex;align-items:center;gap:7px}
  .sect::after{content:"";flex:1;height:1px;background:var(--line-2)}
  .note{padding:9px 11px;border-radius:8px;font-size:12px;line-height:1.6;border:1px solid}
  .note.safe{background:var(--safe-bg);border-color:var(--safe-line);color:var(--safe)}
  .note.caution{background:var(--warn-bg);border-color:var(--warn-line);color:var(--warn)}
  .note.danger{background:var(--dang-bg);border-color:var(--dang-line);color:var(--dang)}
  code{background:var(--panel-2);border:1px solid var(--line);border-radius:5px;padding:1px 5px;font:12px/1.5 Consolas,"Cascadia Mono",monospace;color:#334}
  .cmdbox{width:100%;min-height:62px;resize:vertical;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel-2);color:var(--text);font:12px/1.55 Consolas,monospace;outline:none}
  .cmdbox:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
  .warnbox{margin:10px 0;padding:10px 12px;border-radius:8px;background:var(--dang-bg);border:1px solid var(--dang-line);color:var(--dang);font-size:12px;line-height:1.6}

  /* ---------- modal ---------- */
  .mask{position:fixed;inset:0;background:rgba(16,24,40,.42);z-index:80;display:none;align-items:center;justify-content:center;padding:24px}
  .mask.open{display:flex}
  .modal{background:var(--panel);border-radius:12px;box-shadow:0 24px 60px rgba(16,24,40,.28);width:720px;max-width:100%;max-height:88vh;display:flex;flex-direction:column;overflow:hidden}
  .modal h3{margin:0;padding:16px 20px;border-bottom:1px solid var(--line);font-size:15px;font-weight:650}
  .modal .mb{padding:16px 20px;overflow:auto;flex:1}
  .modal .mf{padding:13px 20px;border-top:1px solid var(--line);display:flex;gap:10px;justify-content:flex-end;align-items:center;background:var(--panel-2);flex-wrap:wrap}
  .steps{display:flex;flex-direction:column;gap:9px}
  .step{border:1px solid var(--line);border-radius:9px;padding:10px 12px;background:var(--panel-2)}
  .step .t{display:flex;gap:8px;align-items:center;margin-bottom:6px;flex-wrap:wrap}
  .step .t b{font-weight:600}
  .step code{display:block;margin-top:5px;word-break:break-all;white-space:pre-wrap}
  .log{background:#0f1723;color:#cfe3ff;border-radius:9px;padding:12px 14px;font:12px/1.65 Consolas,monospace;max-height:330px;overflow:auto;white-space:pre-wrap;word-break:break-all}
  .log .ok{color:#7ee2a8}.log .bad{color:#ff9d92}.log .hd{color:#8ab4ff;font-weight:600}
  .confirm-input{width:100%;padding:9px 11px;border:1px solid var(--dang-line);border-radius:8px;background:var(--panel);color:var(--text);outline:none;font-family:Consolas,monospace}
  .confirm-input:focus{border-color:var(--dang);box-shadow:0 0 0 3px var(--dang-bg)}

  /* ---------- leftover ---------- */
  .lgrid{display:flex;flex-direction:column;gap:14px;padding:16px}
  .lcard{border:1px solid var(--line);border-radius:10px;overflow:hidden;background:var(--panel)}
  .lcard>.lh{padding:11px 14px;background:var(--panel-2);border-bottom:1px solid var(--line);display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .lcard .lh b{font-size:13.5px}
  .lcols{display:grid;grid-template-columns:1fr 1fr;gap:0}
  @media(max-width:1000px){.lcols{grid-template-columns:1fr}}
  .lcol{padding:10px 14px}
  .lcol+.lcol{border-left:1px solid var(--line-2)}
  .lcol h5{margin:0 0 8px;font-size:12px;color:var(--text-3);font-weight:600;letter-spacing:.3px}
  .litem{display:flex;gap:9px;align-items:flex-start;padding:6px 8px;border-radius:7px}
  .litem:hover{background:var(--panel-2)}
  .litem .p{flex:1;font:12px/1.5 Consolas,monospace;color:var(--text);word-break:break-all}
  .litem .w{font-size:11px;color:var(--text-3);margin-top:2px;font-family:inherit}
  .litem .sz{font-size:11px;color:var(--text-2);white-space:nowrap;text-align:right;min-width:64px}
  .empty{padding:40px;text-align:center;color:var(--text-3)}
  .empty b{display:block;color:var(--text-2);margin-bottom:5px;font-size:13px}

  /* ---------- misc ---------- */
  .toast{
    position:fixed;left:50%;transform:translateX(-50%) translateY(-14px);bottom:78px;z-index:120;
    background:#1f2733;color:#fff;padding:10px 16px;border-radius:9px;font-size:13px;
    box-shadow:0 10px 28px rgba(16,24,40,.3);opacity:0;transition:.22s;pointer-events:none;max-width:80vw;
  }
  .toast.show{opacity:1;transform:translateX(-50%)}
  .toast.err{background:var(--dang)}
  .toast.ok{background:var(--safe)}
  .spin{display:inline-block;width:13px;height:13px;border:2px solid rgba(255,255,255,.35);border-top-color:#fff;border-radius:50%;animation:sp .7s linear infinite;vertical-align:-2px}
  .spin.dark{border-color:var(--line);border-top-color:var(--accent)}
  @keyframes sp{to{transform:rotate(360deg)}}
  .muted{color:var(--text-3)}
  .row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
  .hint{font-size:12px;color:var(--text-3);line-height:1.6}
  .banner{margin:14px 22px 0;padding:12px 15px;border-radius:10px;background:var(--warn-bg);border:1px solid var(--warn-line);color:var(--warn);font-size:12.5px;line-height:1.65}
  .banner b{font-weight:650}
</style>
</head>
<body>

<header>
  <div class="brand"><span class="dot"></span>完全卸载面板</div>
  <div class="env" id="env"></div>
</header>

<div class="stats" id="stats"></div>

<div class="banner">
  <b>操作须知：</b>卸载采用「官方卸载程序 + 深度残留清理」两段式。第一步调起厂商自带卸载器（MSI / EXE / AppX），第二步扫描注册表、ProgramData、AppData 中的残留。残留默认<b>移动进隔离区而非直接删除</b>，可随时还原；确认真无用时再送回收站。执行卸载前会自动为所选软件做一次注册表快照，可一键写回。
</div>

<div class="tabs">
  <button class="tab active" data-tab="list">软件清单<span class="n" id="tabN1">0</span></button>
  <button class="tab" data-tab="leftover">残留清理<span class="n" id="tabN2">0</span></button>
  <button class="tab" data-tab="quarantine">隔离区<span class="n" id="tabN3">0</span></button>
</div>

<div class="shell">
  <div class="card" id="viewList">
    <div class="toolbar">
      <div class="search">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
        <input id="q" placeholder="搜索软件名 / 发行商 / 版本…">
      </div>
      <div class="filters" id="filters"></div>
      <div class="spacer"></div>
      <select id="sort" class="btn">
        <option value="size">按体积排序</option>
        <option value="risk">按风险排序</option>
        <option value="name">按名称排序</option>
        <option value="date">按安装日期排序</option>
      </select>
      <button class="btn" id="selVisible">勾选当前列表</button>
      <button class="btn ghost" id="clearSel">清空选择</button>
    </div>
    <div style="max-height:calc(100vh - 330px);overflow:auto">
      <table>
        <thead>
          <tr>
            <th style="width:38px"><input type="checkbox" id="checkAll"></th>
            <th class="sortable" style="width:36%">软件名称</th>
            <th class="sortable" style="width:20%">发行商</th>
            <th style="width:8%">版本</th>
            <th class="sortable" style="width:9%">体积</th>
            <th style="width:8%">安装日期</th>
            <th style="width:9%">来源</th>
            <th style="width:10%">风险评估</th>
          </tr>
        </thead>
        <tbody id="tbody"></tbody>
      </table>
    </div>
  </div>

  <div class="card" id="viewLeftover" style="display:none">
    <div class="toolbar">
      <div class="hint" id="loHint">卸载完成后，这里会列出注册表与磁盘上的残留项。</div>
      <div class="spacer"></div>
      <button class="btn" id="loRescan">重新扫描残留</button>
      <button class="btn primary" id="loQuarantine">隔离所选残留</button>
    </div>
    <div class="lgrid" id="loBody"></div>
  </div>

  <div class="card" id="viewQuarantine" style="display:none">
    <div class="toolbar">
      <div class="hint">隔离区中的文件可还原回原位置；确认无用后再送回收站。删除的注册表项在删除前会先落一份 JSON 快照（可一键写回）。</div>
      <div class="spacer"></div>
      <button class="btn" id="qRefresh">刷新</button>
    </div>
    <div class="lgrid" id="qBody"></div>
  </div>
</div>

<div class="actionbar">
  <span class="sel" id="selCount">已选 0 项</span>
  <span class="sum" id="selSum"></span>
  <div class="spacer"></div>
  <button class="btn" id="btnBackup">① 系统备份（还原点+注册表）</button>
  <button class="btn" id="btnPreview">② 预览卸载命令</button>
  <button class="btn danger" id="btnUninstall">③ 开始卸载</button>
</div>

<aside class="drawer" id="drawer">
  <div class="dh">
    <div style="flex:1">
      <h3 id="dName">—</h3>
      <div class="muted" style="font-size:12px;margin-top:3px" id="dSub"></div>
    </div>
    <button class="btn sm ghost" id="dClose">关闭</button>
  </div>
  <div class="db" id="dBody"></div>
</aside>

<div class="mask" id="mask"><div class="modal" id="modal"></div></div>
<div class="toast" id="toast"></div>

<script>
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const state = { apps:[], env:{}, stats:{}, filter:'uninstallable', q:'', sort:'size', sel:new Set(),
                backup:null, overrides:{}, mode:'silent', leftover:null, lastJobIds:[] };

const FILTERS = [
  {k:'uninstallable', label:'可卸载'},
  {k:'safe',   label:'安全可删'},
  {k:'caution',label:'需谨慎'},
  {k:'danger', label:'高风险'},
  {k:'store',  label:'商店应用'},
  {k:'desktop',label:'桌面程序'},
  {k:'system', label:'系统组件/不可卸载'},
  {k:'selected',label:'已勾选'},
  {k:'all',    label:'全部'},
];

function toast(msg, kind){
  const t = $('#toast'); t.textContent = msg; t.className = 'toast show ' + (kind||'');
  clearTimeout(t._t); t._t = setTimeout(()=>t.className='toast', 3200);
}
async function api(path, body){
  const r = await fetch(path, body ? {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)} : {});
  const d = await r.json().catch(()=>({error:'响应解析失败'}));
  if(!r.ok) throw new Error(d.error || ('HTTP '+r.status));
  return d;
}
function fmtSize(kb){
  if(!kb) return '—';
  const b = kb*1024;
  return b>=1073741824 ? (b/1073741824).toFixed(2)+' GB' : (b/1048576).toFixed(1)+' MB';
}
function fmtBytes(b){
  if(b===null||b===undefined) return '—';
  return b>=1073741824 ? (b/1073741824).toFixed(2)+' GB'
       : b>=1048576 ? (b/1048576).toFixed(1)+' MB'
       : b>=1024 ? (b/1024).toFixed(0)+' KB' : b+' B';
}
function fmtDate(s){
  if(!s) return '—';
  if(/^\d{8}$/.test(s)) return s.slice(0,4)+'-'+s.slice(4,6)+'-'+s.slice(6);
  return s.slice(0,10);
}
const RISK_LABEL = {safe:'安全', caution:'谨慎', danger:'高风险'};

function renderEnv(){
  const e = state.env, st = state.stats;
  $('#env').innerHTML =
    '<span class="chip">主机 <b>'+(e.machine||'-')+'</b></span>'+
    '<span class="chip">'+(e.os||'-')+'</span>'+
    '<span class="chip">C 盘可用 <b>'+(st.freeGB||0)+' GB</b></span>'+
    (state.elevated ? '<span class="chip ok">管理员权限 · 可深度卸载</span>'
                    : '<span class="chip" style="background:var(--dang-bg);border-color:var(--dang-line);color:var(--dang)">非管理员 · 部分软件无法卸载</span>');
  $('#stats').innerHTML = [
    ['已安装软件总数', st.total, '项'],
    ['桌面程序', st.desktop, '项'],
    ['商店应用', st.store, '项'],
    ['其中可卸载', st.uninstallable, '项'],
    ['安全可删', st.safe, '项'],
    ['需谨慎', st.caution, '项'],
    ['高风险', st.danger, '项'],
    ['系统组件/不可卸载', st.system, '项'],
  ].map(([k,v,u])=>`<div class="stat"><div class="k">${k}</div><div class="v">${v||0}<small>${u}</small></div></div>`).join('');
  $('#tabN1').textContent = st.total||0;
}

function passFilter(a){
  switch(state.filter){
    case 'all': return true;
    case 'uninstallable': return a.uninstallable;
    case 'system': return !a.uninstallable;
    case 'safe': case 'caution': case 'danger': return a.risk===state.filter && a.uninstallable;
    case 'store': return a.category==='store';
    case 'desktop': return a.category==='desktop';
    case 'selected': return state.sel.has(a.id);
    default: return true;
  }
}
function visibleApps(){
  const q = state.q.trim().toLowerCase();
  let arr = state.apps.filter(passFilter);
  if(q) arr = arr.filter(a => (a.name+' '+(a.publisher||'')+' '+(a.version||'')).toLowerCase().includes(q));
  const rk = {danger:0, caution:1, safe:2};
  const cmp = {
    size:(a,b)=>((b.sizeKB||0)-(a.sizeKB||0)) || a.name.localeCompare(b.name,'zh'),
    risk:(a,b)=>(rk[a.risk]-rk[b.risk]) || ((b.sizeKB||0)-(a.sizeKB||0)),
    name:(a,b)=>a.name.localeCompare(b.name,'zh'),
    date:(a,b)=>String(b.installDate||'').localeCompare(String(a.installDate||'')),
  }[state.sort];
  return arr.sort(cmp);
}
function renderFilters(){
  const cnt = {
    all: state.apps.length,
    uninstallable: state.apps.filter(a=>a.uninstallable).length,
    system: state.apps.filter(a=>!a.uninstallable).length,
    safe: state.apps.filter(a=>a.risk==='safe'&&a.uninstallable).length,
    caution: state.apps.filter(a=>a.risk==='caution'&&a.uninstallable).length,
    danger: state.apps.filter(a=>a.risk==='danger'&&a.uninstallable).length,
    store: state.apps.filter(a=>a.category==='store').length,
    desktop: state.apps.filter(a=>a.category==='desktop').length,
    selected: state.sel.size,
  };
  $('#filters').innerHTML = FILTERS.map(f =>
    `<button class="f${state.filter===f.k?' active':''}" data-f="${f.k}">${f.label}<span class="n">${cnt[f.k]||0}</span></button>`).join('');
}
function renderTable(){
  const arr = visibleApps();
  const rows = arr.map(a=>{
    const dis = !a.uninstallable;
    const checked = state.sel.has(a.id);
    const srcTag = a.category==='store' ? '<span class="tag appx">商店</span>'
      : a.kind==='msi' ? '<span class="tag msi">MSI</span>'
      : a.kind==='exe' ? '<span class="tag exe">EXE</span>'
      : '<span class="tag">系统</span>';
    return `<tr class="${checked?'sel':''} ${dis?'disabled':''}" data-id="${esc(a.id)}">
      <td><input type="checkbox" data-id="${esc(a.id)}" ${checked?'checked':''} ${dis?'disabled':''}></td>
      <td><div class="nm">${esc(a.name)}</div></td>
      <td><div class="pub" title="${esc(a.publisher||'')}">${esc(a.publisher||'—')}</div></td>
      <td class="ver">${esc(a.version||'—')}</td>
      <td>${fmtSize(a.sizeKB)}</td>
      <td class="ver">${fmtDate(a.installDate)}</td>
      <td>${srcTag}</td>
      <td><span class="tag ${a.risk}" title="${esc(a.riskReason||'')}">${RISK_LABEL[a.risk]}</span></td>
    </tr>`;
  }).join('');
  $('#tbody').innerHTML = rows || `<tr><td colspan="8"><div class="empty"><b>没有匹配的软件</b>换个筛选条件或清空搜索词试试</div></td></tr>`;
}
function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

function renderSelection(){
  const n = state.sel.size;
  $('#selCount').textContent = '已选 ' + n + ' 项';
  const kb = [...state.sel].map(id=>state.apps.find(a=>a.id===id)).filter(Boolean)
             .reduce((s,a)=>s+(a.sizeKB||0),0);
  const cnt = {danger:0,caution:0,safe:0};
  [...state.sel].forEach(id=>{ const a=state.apps.find(x=>x.id===id); if(a) cnt[a.risk]++; });
  $('#selSum').innerHTML = n ? `注册表显示体积约 ${fmtSize(kb)}`
      + (cnt.danger?` · <span style="color:var(--dang)">高风险 ${cnt.danger}</span>`:'')
      + (cnt.caution?` · <span style="color:var(--warn)">需谨慎 ${cnt.caution}</span>`:'')
      + ' · 单批上限 10 项' : '';
  $('#btnUninstall').disabled = n===0;
  $('#btnPreview').disabled = n===0;
}

function openDrawer(a){
  $('#dName').textContent = a.name;
  $('#dSub').textContent = (a.publisher||'未知发行商') + ' · ' + (a.version||'无版本信息');
  const ov = state.overrides[a.id];
  const defaultCmd = state.mode==='silent' ? (a.silentCmd||'') : (a.interactiveCmd||a.uninstall||'');
  const rows = [
    ['唯一标识', a.id], ['卸载方式', a.kind==='appx'?'Store 应用包 (AppX)':a.kind==='msi'?'Windows Installer (MSI)':a.kind==='exe'?'厂商自带卸载程序 (EXE)':'无自动卸载程序'],
    ['架构', a.arch||'—'], ['作用域', a.scope==='Machine'?'全机所有用户':'仅当前用户'],
    ['注册表体积', fmtSize(a.sizeKB)], ['安装日期', fmtDate(a.installDate)],
    ['安装位置', a.installLoc||'—'],
    ['注册表键', a.regRoot ? a.regRoot+'\\'+a.regKey : '—'],
    ['原始卸载命令', a.uninstall||a.quietUninstall||'—'],
  ];
  $('#dBody').innerHTML = `
    <div class="note ${a.risk}"><b>风险评级：${RISK_LABEL[a.risk]}</b><br>${esc(a.riskReason||'')}</div>
    <div class="sect">基本信息</div>
    <div class="kv">${rows.map(([k,v])=>`<div class="k">${k}</div><div class="v">${esc(v)}</div>`).join('')}</div>
    <div class="sect">残留匹配令牌</div>
    <div>${(a.tokens&&a.tokens.length? a.tokens : ['无']).map(t=>`<code>${esc(t)}</code>`).join(' ')}</div>
    <div class="sect">卸载命令（可自定义）</div>
    <div class="hint" style="margin-bottom:7px">留空则使用默认策略：${state.mode==='silent'?'静默卸载（无界面，失败多的软件建议改用交互模式）':'交互卸载（弹出厂商卸载向导，最稳妥）'}</div>
    <textarea class="cmdbox" id="dCmd" placeholder="${esc(defaultCmd||'该软件无可用卸载命令，需手动处理')}">${esc(ov||'')}</textarea>
    <div class="row" style="margin-top:9px">
      <button class="btn sm" id="dCalc">计算实际占用</button>
      <button class="btn sm" id="dOpen">打开安装目录</button>
      <button class="btn sm" id="dSave">保存自定义命令</button>
    </div>
    <div id="dCalcOut" class="hint" style="margin-top:8px"></div>
    <div class="sect">勾选</div>
    <button class="btn ${state.sel.has(a.id)?'danger':''}" id="dToggle" style="width:100%">${state.sel.has(a.id)?'从待卸载列表移除':'加入待卸载列表'}</button>
  `;
  $('#dSave').onclick = ()=>{ const v = $('#dCmd').value.trim(); if(v) state.overrides[a.id]=v; else delete state.overrides[a.id]; toast('已保存自定义卸载命令','ok'); };
  $('#dToggle').onclick = ()=>{ toggleSel(a.id); openDrawer(a); };
  $('#dCalc').onclick = async ()=>{
    const p = a.installLoc ? a.installLoc.split(';')[0].trim() : '';
    if(!p){ $('#dCalcOut').textContent='注册表未记录安装目录，可在残留扫描中获得实际体积。'; return; }
    $('#dCalcOut').innerHTML = '<span class="spin dark"></span> 正在统计 '+esc(p);
    try{ const r = await api('/api/size',{paths:[p]}); const s=r.sizes[p];
      $('#dCalcOut').textContent = '实际占用 ' + fmtBytes(s.bytes) + '（' + s.files + ' 个文件' + (s.capped?'，已达扫描上限，实际更大':'') + '）';
    }catch(e){ $('#dCalcOut').textContent = '统计失败：'+e.message; }
  };
  $('#dOpen').onclick = async ()=>{
    const p = (a.installLoc||'').split(';')[0].trim();
    if(!p) return toast('无安装目录信息','err');
    try{ await api('/api/open', {path:p}); toast('已在资源管理器中打开'); }
    catch(e){ toast('打开失败：'+e.message,'err'); }
  };
  $('#drawer').classList.add('open');
}
function toggleSel(id){
  if(state.sel.has(id)) state.sel.delete(id); else state.sel.add(id);
  renderTable(); renderSelection(); renderFilters();
}

function showModal(html){ $('#modal').innerHTML = html; $('#mask').classList.add('open'); }
function closeModal(){ $('#mask').classList.remove('open'); }

/* ---------- 备份 ---------- */
async function doBackup(silent){
  const b = $('#btnBackup');
  b.disabled = true; b.innerHTML = '<span class="spin dark"></span> 正在备份…';
  try{
    const r = await api('/api/backup', {note:'panel'});
    state.backup = {at:new Date().toISOString(), restorePoint:r.restorePoint};
    const info = r.info||{};
    const rpOk = r.restorePoint;
    toast(rpOk ? '备份完成：已创建系统还原点并快照注册表'
               : '注册表快照已完成（系统还原点不可用，见详情）', rpOk?'ok':'');
    if(!silent){
      const cp = String(info.checkpoint||'');
      showModal(`<h3>备份结果</h3><div class="mb">
        <div class="note ${rpOk?'safe':'caution'}">
          ${rpOk?'✅ 系统还原点创建成功，出问题可在「系统还原」中回滚到本次操作之前。'
                :'⚠ 系统还原点未能创建：'+esc(cp)+'<br>本机系统保护（System Protection）未开启。如需还原点，请到「此电脑 → 属性 → 系统保护」手动为 C 盘开启，再回来点一次备份。'}
        </div>
        <div class="sect">注册表快照（可一键还原）</div>
        <div style="margin-bottom:8px"><code>${esc(r.regDir||'')}</code></div>
        <div class="kv">
          <div class="k">快照键数</div><div class="v">${(r.snapshot&&r.snapshot.ok)||0} / ${(r.snapshot&&r.snapshot.total)||0} 个键，含全部子键与值</div>
          <div class="k">说明</div><div class="v">本机安全策略禁用 reg.exe，因此改用自研 JSON 快照（内容等价、可程序化还原），存放于 backups 目录，可在「隔离区」页签一键还原。</div>
        </div>
        ${info.enableSr && info.enableSr!=='ok' && info.enableSr!=='skipped' ? '<div class="hint">开启系统保护尝试结果：'+esc(info.enableSr)+'</div>':''}
        ${(info.points&&info.points.length)?'<div class="sect">已有还原点</div><div class="hint">'+info.points.map(esc).join('<br>')+'</div>':''}
      </div><div class="mf"><button class="btn primary" onclick="closeModal()">知道了</button></div>`);
    }
  }catch(e){ toast('备份失败：'+e.message,'err'); }
  b.disabled = false; b.innerHTML = '① 系统备份 ✅';
}

/* ---------- 预览 ---------- */
async function doPreview(goUninstall){
  const ids = [...state.sel];
  if(ids.length > 10) return toast('单批最多 10 项，请减少选择','err');
  let r;
  try{ r = await api('/api/preview', {ids, mode:state.mode, overrides:state.overrides}); }
  catch(e){ return toast('预览失败：'+e.message,'err'); }
  const steps = r.steps||[];
  const risky = steps.filter(s=>s.risk!=='safe');
  showModal(`<h3>卸载命令预览 · 共 ${steps.length} 项</h3><div class="mb">
    <div class="row" style="margin-bottom:12px">
      <span class="hint">执行模式：</span>
      <button class="f ${state.mode==='silent'?'active':''}" data-mode="silent">静默卸载</button>
      <button class="f ${state.mode==='interactive'?'active':''}" data-mode="interactive">交互卸载（弹出向导）</button>
    </div>
    ${risky.length?`<div class="warnbox"><b>注意：${risky.length} 项存在风险</b><br>${risky.map(s=>'· '+esc(s.name)+'：'+esc(s.riskReason)).join('<br>')}</div>`:''}
    <div class="steps">${steps.map((s,i)=>`<div class="step">
      <div class="t"><b>${i+1}. ${esc(s.name)}</b>
        <span class="tag ${s.risk}">${RISK_LABEL[s.risk]}</span>
        <span class="tag">${s.kind.toUpperCase()}</span></div>
      <code>${esc(s.cmd)}</code>
      ${s.note?`<div class="hint" style="margin-top:5px">${esc(s.note)}</div>`:''}
    </div>`).join('')}</div>
  </div><div class="mf">
    <span class="hint" style="margin-right:auto">${state.backup?'✅ 已完成系统备份':'⚠ 尚未执行系统备份'}</span>
    <button class="btn" onclick="closeModal()">取消</button>
    <button class="btn" id="pvBackup">先做系统备份</button>
    <button class="btn ${goUninstall?'danger':'primary'}" id="pvNext">${goUninstall?'下一步：确认卸载':'确认命令无误'}</button>
  </div>`);
  $$('#modal .f[data-mode]').forEach(b=>b.onclick=()=>{ state.mode=b.dataset.mode; doPreview(goUninstall); });
  $('#pvBackup').onclick = ()=>{ closeModal(); doBackup(false); };
  $('#pvNext').onclick = ()=>{ goUninstall ? confirmUninstall(steps) : closeModal(); };
}

/* ---------- 卸载确认 ---------- */
function confirmUninstall(steps){
  const danger = steps.filter(s=>s.risk==='danger');
  showModal(`<h3>最后确认</h3><div class="mb">
    <div class="warnbox">此操作将调用各软件自带的卸载程序，<b>过程不可中断</b>（部分软件的卸载向导需要你在弹出的窗口中点确认）。<br>
    卸载完成后，面板会继续提供残留清理。</div>
    ${danger.length?`<div class="note danger" style="margin-bottom:10px"><b>其中 ${danger.length} 项被标记为高风险：</b><br>${danger.map(s=>'· '+esc(s.name)).join('<br>')}</div>`:''}
    <div class="hint" style="margin-bottom:8px">将卸载以下 ${steps.length} 项：</div>
    <div style="margin-bottom:14px">${steps.map(s=>`<span class="tag ${s.risk}" style="margin:0 5px 5px 0">${esc(s.name)}</span>`).join('')}</div>
    <div class="hint" style="margin-bottom:6px">请输入 <code>确认卸载</code> 以继续：</div>
    <input class="confirm-input" id="cfm" placeholder="确认卸载" autocomplete="off">
  </div><div class="mf">
    <button class="btn" onclick="closeModal()">取消</button>
    <button class="btn danger" id="cfmGo" disabled>执行卸载</button>
  </div>`);
  const inp = $('#cfm'), go = $('#cfmGo');
  inp.focus();
  inp.oninput = ()=>{ go.disabled = inp.value.trim()!=='确认卸载'; };
  inp.onkeydown = e => { if(e.key==='Enter' && !go.disabled) go.click(); };
  go.onclick = async ()=>{
    go.disabled = true; go.innerHTML = '<span class="spin"></span> 启动中…';
    const ids = [...state.sel];
    try{
      const r = await api('/api/uninstall', {ids, mode:state.mode, overrides:state.overrides, confirm:'UNINSTALL'});
      state.lastJobIds = ids;
      runJob(r.jobId, r.blocked||[], steps);
    }catch(e){
      go.disabled = false; go.textContent = '执行卸载';
      toast('启动失败：'+e.message,'err');
    }
  };
}

/* ---------- 作业进度 ---------- */
function runJob(jobId, blocked, steps){
  showModal(`<h3>正在卸载…</h3><div class="mb">
    <div class="row" style="margin-bottom:10px">
      <span class="spin dark"></span>
      <b id="jbStatus">准备中…</b>
      <span class="hint" id="jbCount"></span>
    </div>
    ${blocked.length?`<div class="note caution" style="margin-bottom:10px">${blocked.map(b=>'· '+esc(b.name)+'：'+esc(b.why)).join('<br>')}</div>`:''}
    <div class="log" id="jbLog"></div>
  </div><div class="mf">
    <span class="hint" style="margin-right:auto" id="jbHint">卸载向导若弹出窗口，请在其中确认。</span>
    <button class="btn primary" id="jbDone" disabled>完成并扫描残留</button>
  </div>`);
  const ids = Object.fromEntries(steps.map(s=>[s.name, s.id]));
  let done = false;
  const tick = async ()=>{
    let d;
    try{ d = await api('/api/job?id='+encodeURIComponent(jobId)); }catch(e){ return; }
    const res = d.results||[];
    $('#jbCount').textContent = `${res.length} / ${steps.length} 已完成`;
    $('#jbLog').innerHTML = (d.log||[]).slice(-260).map(ln=>{
      let cls = '';
      if(/^===/.test(ln)) cls='hd';
      else if(/ERROR|FAIL|exit=[1-9]/.test(ln)) cls='bad';
      else if(/verify: registry key gone = True|exit=0/.test(ln)) cls='ok';
      return `<span class="${cls}">${esc(ln)}</span>`;
    }).join('\n');
    $('#jbLog').scrollTop = $('#jbLog').scrollHeight;
    if(d.status==='done'){
      done = true;
      const ok = res.filter(r=>r.ok).length, bad = res.length-ok;
      $('#jbStatus').textContent = `卸载流程结束：成功 ${ok} 项` + (bad?`，失败/需人工处理 ${bad} 项`:'');
      $('#jbHint').textContent = '残留文件与注册表项将在下一步扫描。';
      $('#modal .spin') && $('#modal .spin').remove();
      $('#jbDone').disabled = false;
      clearInterval(iv);
    }
  };
  const iv = setInterval(()=>{ if(!done) tick(); else clearInterval(iv); }, 900);
  tick();
  $('#jbDone').onclick = ()=>{
    closeModal();
    state.sel = new Set(state.lastJobIds);
    switchTab('leftover');
    scanLeftover();
  };
}

/* ---------- 残留扫描 ---------- */
async function scanLeftover(){
  const ids = [...state.sel];
  if(!ids.length) return toast('请先在软件清单里选择已卸载的软件','err');
  $('#loHint').innerHTML = '<span class="spin dark"></span> 正在扫描注册表与磁盘残留…（视软件体积，可能需要几十秒）';
  $('#loBody').innerHTML = '';
  try{
    const r = await api('/api/leftover', {ids});
    state.leftover = r;
    renderLeftover(r);
  }catch(e){ $('#loHint').textContent = '扫描失败：'+e.message; toast('扫描失败：'+e.message,'err'); }
}
function renderLeftover(r){
  const items = (r.items||[]);
  const nf = items.reduce((s,i)=>s+i.files.length,0);
  const nr = items.reduce((s,i)=>s+i.regs.length,0);
  $('#tabN2').textContent = nf+nr;
  $('#loHint').innerHTML = `扫描完成：发现 <b>${nf}</b> 个残留目录/文件、<b>${nr}</b> 个残留注册表项。勾选后点击「隔离所选残留」。`;
  if(!nf && !nr){
    $('#loBody').innerHTML = `<div class="empty"><b>没有发现残留</b>该软件的卸载程序已经清理干净了 🎉</div>`;
    return;
  }
  $('#loBody').innerHTML = items.filter(i=>i.files.length||i.regs.length).map(i=>{
    const lowN = i.files.filter(f=>f.conf==='low').length + i.regs.filter(g=>g.conf==='low').length;
    return `
    <div class="lcard">
      <div class="lh">
        <b>${esc(i.name)}</b>
        <span class="tag">${i.files.length} 个文件项</span>
        <span class="tag">${i.regs.length} 个注册表项</span>
        ${lowN?`<span class="tag caution">${lowN} 项疑似属于其他软件</span>`:''}
        <div class="spacer" style="flex:1"></div>
        <button class="btn sm" data-all="${esc(i.id)}">全选（仅高可信）</button>
        <button class="btn sm" data-size="${esc(i.id)}">计算体积</button>
      </div>
      <div class="lcols">
        <div class="lcol">
          <h5>磁盘残留</h5>
          ${i.files.length? i.files.map(f=>`<label class="litem" ${f.conf==='low'?'style="background:var(--warn-bg)"':''}>
            <input type="checkbox" data-kind="file" data-path="${esc(f.path)}" ${f.conf==='low'?'':'checked'}>
            <span class="p">${esc(f.path)}<span class="w">${esc(f.why)} · 可信度 ${f.conf==='high'?'高':f.conf==='mid'?'中':'低（需你确认）'}</span></span>
            <span class="sz" data-sz="${esc(f.path)}">—</span></label>`).join('')
          : '<div class="hint">无</div>'}
        </div>
        <div class="lcol">
          <h5>注册表残留</h5>
          ${i.regs.length? i.regs.map(g=>`<label class="litem" ${g.conf==='low'?'style="background:var(--warn-bg)"':''}>
            <input type="checkbox" data-kind="reg" data-path="${esc(g.path)}" ${g.conf==='low'?'':'checked'}>
            <span class="p">${esc(g.path)}<span class="w">${esc(g.why)} · 可信度 ${g.conf==='high'?'高':g.conf==='mid'?'中':'低（需你确认）'}</span></span>
            <span class="sz">注册表</span></label>`).join('')
          : '<div class="hint">无</div>'}
        </div>
      </div>
    </div>`;}).join('');
  $$('#loBody [data-all]').forEach(b=>b.onclick=()=>{
    const card = b.closest('.lcard');
    card.querySelectorAll('input[type=checkbox]').forEach(c=>{
      const row = c.closest('.litem');
      if(!row || !row.style.background) c.checked = true;
    });
  });
  $$('#loBody [data-size]').forEach(b=>b.onclick=async ()=>{
    const card = b.closest('.lcard');
    const paths = [...card.querySelectorAll('[data-kind=file]')].map(c=>c.dataset.path);
    if(!paths.length) return toast('无磁盘残留可统计');
    b.disabled = true; b.innerHTML = '<span class="spin dark"></span>';
    try{
      const s = await api('/api/size', {paths});
      let total = 0;
      for(const p of paths){
        const info = s.sizes[p]; total += info.bytes||0;
        [...card.querySelectorAll('[data-sz]')].forEach(el=>{
          if(el.dataset.sz === p) el.textContent = info.missing ? '不存在' : fmtBytes(info.bytes) + (info.capped?'+':'');
        });
      }
      toast('残留总体积约 ' + fmtBytes(total),'ok');
    }catch(e){ toast('统计失败：'+e.message,'err'); }
    b.disabled = false; b.textContent = '计算体积';
  });
}
async function quarantineSelected(){
  const files = $$('#loBody input[data-kind=file]:checked').map(c=>c.dataset.path);
  const regs  = $$('#loBody input[data-kind=reg]:checked').map(c=>c.dataset.path);
  if(!files.length && !regs.length) return toast('未勾选任何残留项','err');
  let totalBytes = 0;
  $$('#loBody [data-sz]').forEach(el=>{ const m=/([\d.]+) (GB|MB|KB)/.exec(el.textContent); if(m){ const n=parseFloat(m[1]); totalBytes += m[2]==='GB'?n*1073741824:m[2]==='MB'?n*1048576:n*1024; } });
  showModal(`<h3>隔离确认</h3><div class="mb">
    <div class="note safe"><b>这是可逆操作。</b>残留文件会被<b>移动</b>到隔离区（不是删除）；注册表项会先落一份<b>可一键写回的 JSON 快照</b>再删除。之后你可以在「隔离区」标签页还原。</div>
    <div class="sect">本次将处理</div>
    <div class="kv">
      <div class="k">磁盘残留</div><div class="v">${files.length} 项${totalBytes>0?'，约 '+fmtBytes(totalBytes)+'（部分未统计体积）':''}</div>
      <div class="k">注册表项</div><div class="v">${regs.length} 项</div>
    </div>
    <div style="max-height:220px;overflow:auto;border:1px solid var(--line);border-radius:8px;padding:9px;background:var(--panel-2)">
      ${files.concat(regs).map(p=>`<div class="hint" style="font-family:Consolas,monospace;word-break:break-all">${esc(p)}</div>`).join('')}
    </div>
  </div><div class="mf">
    <button class="btn" onclick="closeModal()">取消</button>
    <button class="btn primary" id="qGo">确认隔离</button>
  </div>`);
  $('#qGo').onclick = async ()=>{
    $('#qGo').disabled = true; $('#qGo').innerHTML = '<span class="spin"></span> 处理中…';
    try{
      const r = await api('/api/quarantine', {paths:files, regkeys:regs});
      const e = r.entry;
      const moved = e.files.filter(f=>f.status==='moved').length;
      const failed = e.files.filter(f=>f.status==='failed');
      closeModal();
      toast(`已隔离 ${moved} 个文件项、${(e.regs||[]).length} 个注册表项` + (failed.length?`，${failed.length} 项失败`:'') ,'ok');
      if(failed.length) console.warn(failed);
      scanLeftover();
      loadQuarantine();
    }catch(e){ toast('隔离失败：'+e.message,'err'); $('#qGo').disabled=false; $('#qGo').textContent='确认隔离'; }
  };
}

/* ---------- 隔离区 ---------- */
function bindRegRestore(){
  $$('#qBody [data-regrestore]').forEach(bt=>{
    if(bt._bound) return;
    bt._bound = true;
    bt.onclick = async ()=>{
      const f = bt.dataset.regrestore;
      if(!confirm('将把该注册表快照写回注册表（同名键值会被覆盖，不会删除其他现有键）。继续？')) return;
      bt.disabled = true; const old = bt.textContent; bt.innerHTML = '<span class="spin dark"></span>';
      try{
        const r = await api('/api/reg-restore',{files:[f]});
        toast(`注册表已还原 ${r.restored.length} 个键` + (r.failed.length?`，${r.failed.length} 个失败`:''), r.failed.length?'':'ok');
      }catch(e){ toast('还原失败：'+e.message,'err'); }
      bt.disabled = false; bt.textContent = old;
    };
  });
}
async function loadQuarantine(){
  let d, snap = {snapshots:[]};
  try{ d = await api('/api/quarantine'); }catch(e){ return; }
  try{ snap = await api('/api/snapshots'); }catch(e){}
  const man = (d.manifest||[]).slice().reverse();
  $('#tabN3').textContent = man.reduce((s,b)=>s+(b.files||[]).filter(f=>f.status==='moved').length,0);
  const snapHtml = (snap.snapshots||[]).length ? `
    <div class="lcard">
      <div class="lh">
        <b>注册表快照 / 回滚点</b>
        <span class="tag">${(snap.snapshots||[]).length} 个</span>
        <div class="hint" style="flex:1">每次备份与每次卸载前都会自动落一份快照，可随时写回注册表</div>
      </div>
      <div class="lcol" style="padding:10px 14px">
        ${(snap.snapshots||[]).map(s=>`<div class="litem">
          <span class="p">${esc(s.file)}<span class="w">${esc(s.label||s.kind)} · ${esc(s.at||'')} · ${s.keys||0} 个键</span></span>
          <button class="btn sm" data-regrestore="${esc(s.file)}">写回注册表</button></div>`).join('')}
      </div>
    </div>` : '';
  if(!man.length){
    $('#qBody').innerHTML = snapHtml + '<div class="empty"><b>隔离区是空的</b>被隔离的残留会出现在这里，可随时还原</div>';
    bindRegRestore();
    return;
  }
  $('#qBody').innerHTML = snapHtml + man.map(b=>{ return `
    <div class="lcard">
      <div class="lh">
        <b>批次 ${esc(b.batch)}</b>
        <span class="tag">${esc(b.at)}</span>
        <span class="tag">${(b.files||[]).filter(f=>f.status==='moved').length} 个文件项</span>
        <span class="tag">${(b.regs||[]).length} 个注册表项</span>
      </div>
      <div class="lcol" style="padding:10px 14px">
        ${(b.files||[]).map(f=>`<label class="litem">
          <input type="checkbox" ${f.status==='moved'?'':'disabled'} data-restore="${esc(f.dest||'')}">
          <span class="p">${esc(f.src)}<span class="w">${f.status==='moved'?'已移入隔离区':f.status==='restored'?'已还原':f.status==='missing'?'扫描时已不存在':'失败：'+esc(f.error||'')}</span></span>
          <span class="sz">${f.isDir?'目录':'文件'}</span></label>`).join('')}
        ${(b.regs||[]).length?`<div class="hint" style="margin-top:8px">注册表快照：<code>${esc((b.regSnapshot||'').split('\\').slice(-2).join('/') || '—')}</code>
          <br>处理结果：${(b.regs||[]).map(g=>esc(g.key.split('\\').slice(-2).join('\\'))+' → '+(g.status==='DELETED'?'已删除':g.status==='MISSING'?'已不存在':'失败')).join('<br>')}</div>`:''}
        <div class="row" style="margin-top:10px">
          <button class="btn sm" data-restore-batch="${esc(b.batch)}">还原所选文件</button>
          ${(b.regSnapshot||'').length?`<button class="btn sm" data-regrestore="${esc(b.regSnapshot)}">还原注册表快照</button>`:''}
          <button class="btn sm danger" data-purge-batch="${esc(b.batch)}">送回收站（回收站仍可恢复）</button>
        </div>
      </div>
    </div>`;}).join('');
  $$('#qBody [data-restore-batch]').forEach(bt=>bt.onclick=async ()=>{
    const card = bt.closest('.lcard');
    const dests = [...card.querySelectorAll('[data-restore]:checked')].map(c=>c.dataset.restore).filter(Boolean);
    if(!dests.length) return toast('未勾选任何项','err');
    try{ const r = await api('/api/restore',{dests});
      toast(`已还原 ${r.restored.length} 项` + (r.failed.length?`，${r.failed.length} 项失败`:''),'ok');
      loadQuarantine();
    }catch(e){ toast('还原失败：'+e.message,'err'); }
  });
  $$('#qBody [data-purge-batch]').forEach(bt=>bt.onclick=async ()=>{
    const card = bt.closest('.lcard');
    const paths = [...card.querySelectorAll('[data-restore]')].map(c=>c.dataset.restore).filter(Boolean);
    if(!paths.length) return toast('该批次没有可清理的项');
    if(!confirm('将把这些项送入回收站（不是永久删除，仍可从回收站恢复）。继续？')) return;
    try{ const r = await api('/api/purge',{paths});
      const ok = (r.results||[]).filter(x=>String(x).startsWith('RECYCLED')).length;
      const bad = (r.results||[]).filter(x=>String(x).startsWith('FAIL'));
      toast('已送入回收站：' + ok + ' 项' + (bad.length?`，${bad.length} 项失败`:'') + '（回收站中仍可恢复）', bad.length?'':'ok');
      await api('/api/quarantine/cleanup',{});
      loadQuarantine();
    }catch(e){ toast('操作失败：'+e.message,'err'); }
  });
  bindRegRestore();
}

/* ---------- tabs ---------- */
function switchTab(name){
  $$('.tab').forEach(t=>t.classList.toggle('active', t.dataset.tab===name));
  $('#viewList').style.display = name==='list'?'':'none';
  $('#viewLeftover').style.display = name==='leftover'?'':'none';
  $('#viewQuarantine').style.display = name==='quarantine'?'':'none';
  if(name==='quarantine') loadQuarantine();
}

/* ---------- init ---------- */
async function init(){
  let d;
  try{ d = await api('/api/state'); }
  catch(e){ document.body.innerHTML = '<div style="padding:40px;font:14px sans-serif">面板数据加载失败：'+esc(e.message)+'</div>'; return; }
  state.apps = d.apps||[]; state.env = d.env||{}; state.stats = d.stats||{};
  state.elevated = !!d.elevated;
  state.backup = d.backup && d.backup.at ? d.backup : null;
  renderEnv(); renderFilters(); renderTable(); renderSelection();
  if(state.backup) $('#btnBackup').innerHTML = '① 系统备份 ✅';

  $('#q').oninput = e => { state.q = e.target.value; renderTable(); };
  $('#sort').onchange = e => { state.sort = e.target.value; renderTable(); };
  $('#filters').onclick = e => {
    const b = e.target.closest('.f'); if(!b) return;
    state.filter = b.dataset.f; renderFilters(); renderTable();
  };
  $('#tbody').onclick = e => {
    const cb = e.target.closest('input[type=checkbox]');
    if(cb){ e.stopPropagation(); toggleSel(cb.dataset.id); return; }
    const tr = e.target.closest('tr'); if(!tr) return;
    const a = state.apps.find(x=>x.id===tr.dataset.id); if(a) openDrawer(a);
  };
  $('#checkAll').onclick = e => {
    const list = visibleApps();
    if(e.target.checked) list.forEach(a=>{ if(a.uninstallable) state.sel.add(a.id); });
    else list.forEach(a=>state.sel.delete(a.id));
    renderTable(); renderSelection(); renderFilters();
  };
  $('#selVisible').onclick = ()=>{
    let n=0; visibleApps().forEach(a=>{ if(a.uninstallable){ state.sel.add(a.id); n++; } });
    renderTable(); renderSelection(); renderFilters(); toast('已勾选当前列表 '+n+' 项');
  };
  $('#clearSel').onclick = ()=>{ state.sel.clear(); renderTable(); renderSelection(); renderFilters(); };
  $('#dClose').onclick = ()=> $('#drawer').classList.remove('open');
  $('#mask').onclick = e => { if(e.target.id==='mask') closeModal(); };
  $$('.tab').forEach(t=>t.onclick=()=>switchTab(t.dataset.tab));
  $('#btnBackup').onclick = ()=>doBackup(false);
  $('#btnPreview').onclick = ()=>doPreview(false);
  $('#btnUninstall').onclick = ()=>doPreview(true);
  $('#loRescan').onclick = ()=>scanLeftover();
  $('#loQuarantine').onclick = ()=>quarantineSelected();
  $('#qRefresh').onclick = ()=>loadQuarantine();
  document.addEventListener('keydown', e=>{ if(e.key==='Escape'){ closeModal(); $('#drawer').classList.remove('open'); } });
}
init();
</script>
</body>
</html>

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

