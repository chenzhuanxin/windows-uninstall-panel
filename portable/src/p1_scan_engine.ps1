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
