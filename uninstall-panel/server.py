# -*- coding: utf-8 -*-
"""
完全卸载面板 · 本地引擎
------------------------------------------------
内置 HTTP 服务，为面板提供：
  - 软件清单（注册表 Uninstall + Store/UWP）
  - 风险分级（系统依赖 / 用户数据 / 纯净可删）
  - 卸载执行（MSI / EXE / AppX），带还原点 + 注册表备份
  - 残留扫描（文件 + 注册表），残留隔离（可还原），不入回收站则需二次确认
所有破坏性动作都有：预览 -> 备份 -> 二次确认 -> 逐项日志。
"""
import os
import re
import sys
import json
import time
import uuid
import socket
import shutil
import threading
import subprocess
import traceback
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import winreg

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
SCAN_JSON = os.path.join(ROOT, 'scanner', 'software_scan.json')
JOBS_DIR = os.path.join(BASE, 'jobs')
QUAR_DIR = os.path.join(BASE, 'quarantine')
BACKUP_DIR = os.path.join(BASE, 'backups')
LOG_DIR = os.path.join(BASE, 'logs')
PS_EXE = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
PORT = 8791

CREATE_NO_WINDOW = 0x08000000
for d in (JOBS_DIR, QUAR_DIR, BACKUP_DIR, LOG_DIR):
    os.makedirs(d, exist_ok=True)

_env = {
    'PROGRAMFILES': os.environ.get('ProgramFiles', r'C:\Program Files'),
    'PROGRAMFILES_X86': os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'),
    'PROGRAMDATA': os.environ.get('ProgramData', r'C:\ProgramData'),
    'LOCALAPPDATA': os.environ.get('LOCALAPPDATA', ''),
    'APPDATA': os.environ.get('APPDATA', ''),
    'USERPROFILE': os.environ.get('USERPROFILE', ''),
    'WINDIR': os.environ.get('SystemRoot', r'C:\Windows'),
}


def now_iso():
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def read_json(path, default=None):
    try:
        with open(path, 'r', encoding='utf-8-sig') as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)


# --------------------------------------------------------------------------
# PowerShell 桥
# --------------------------------------------------------------------------
def run_ps(body, tag='t', timeout=3600):
    """执行 PowerShell 代码：脚本以 UTF-8 BOM 落盘，输出经文件回读，避免控制台编码问题。"""
    sp = os.path.join(JOBS_DIR, '_ps_%s.ps1' % tag)
    with open(sp, 'w', encoding='utf-8-sig') as f:
        f.write(body)
    try:
        p = subprocess.run(
            [PS_EXE, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', sp],
            capture_output=True, timeout=timeout,
            creationflags=CREATE_NO_WINDOW)
        return {
            'rc': p.returncode,
            'stdout': p.stdout.decode('utf-8', 'replace'),
            'stderr': p.stderr.decode('utf-8', 'replace'),
        }
    except subprocess.TimeoutExpired:
        return {'rc': -1, 'stdout': '', 'stderr': 'timeout after %ss' % timeout}
    finally:
        try:
            os.remove(sp)
        except Exception:
            pass


def ps_literal_list(items):
    """生成 PowerShell 单引号字符串数组字面量（反斜杠无需转义，单引号双写）。"""
    return '@(' + ','.join("'" + str(i).replace("'", "''") + "'" for i in items) + ')'


def _ps_reg_path(p):
    """HKLM\\SOFTWARE\\... -> HKLM:\\SOFTWARE\\..."""
    return re.sub(r'^(HKLM|HKCU|HKCR|HKU)\\', r'\1:\\', p or '', flags=re.I)


def ps_json(body, tag='j', timeout=3600):
    """执行 PowerShell 并把 JSON 结果写文件后回读。"""
    out = os.path.join(JOBS_DIR, '_ps_%s.json' % tag)
    if os.path.exists(out):
        os.remove(out)
    body = body.replace('__OUT__', out)
    r = run_ps(body, tag, timeout)
    data = read_json(out, None)
    return {'rc': r['rc'], 'data': data, 'stderr': r['stderr'][:1500]}



# --------------------------------------------------------------------------
# 风险分级
# --------------------------------------------------------------------------
DANGER = [
    (r'redistributable|microsoft visual c\+\+', 'VC++ 运行库：大量已安装软件的底层依赖，卸载后这些程序会直接启动失败。'),
    (r'\.net (framework|runtime|host)', '.NET 运行时：系统与众多应用的框架依赖。'),
    (r'^microsoft edge$|^microsoft edge ', 'Edge 浏览器已与系统深度集成，其内核同时为 WebView2 组件供能，卸载可能影响其他应用内嵌网页。'),
    (r'webview2', 'WebView2 运行时：大量应用内嵌浏览器用它渲染界面。'),
    (r'nvidia|图形驱动程序|graphics driver|display driver', '显卡驱动：卸载会造成显示分辨率异常、性能严重下降，需立刻重装。'),
    (r'windows software development kit|windows sdk', 'Windows SDK：编译与调试工具链的基础组件。'),
    (r'update health tools', 'Windows 更新健康工具：系统自带维护组件。'),
    (r'visual studio installer|visual studio 生成工具|visual studio build tools', 'VS 安装器 / 生成工具：统管多个开发组件，卸载会牵连整套工具链。'),
    (r'tools for office', 'VSTO 运行时：Office 加载项的依赖。'),
    (r'iis url 重写|application request routing', 'IIS 服务器模块：本地 Web 服务组件。'),
    (r'usbdk', 'UsbDk 驱动：虚拟化 / 云电脑 USB 重定向依赖，卸载后相关功能失效。'),
    (r'python launcher', 'py 启动器：Python 命令行的入口组件。'),
    (r'printservice|scan to|hp laserjet|打印机', '打印机 / 扫描仪驱动：卸载后设备无法使用。'),
    (r'microsoft onedrive', 'OneDrive 与系统账户、资源管理器深度集成。'),
    (r'^workbuddy', '⚠ 这是当前正在运行的 WorkBuddy 工作台本体，卸载会立刻中断当前会话。'),
    (r'^python 3\.\d+', '⚠ 本机脚本环境依赖该 Python（面板引擎自身也用它），卸载后自动化能力失效。'),
    (r'^node\.js', '⚠ 本机脚本环境依赖 Node.js。'),
    (r'microsoft visual studio', 'Visual Studio 系列：开发环境主体。'),
    (r'microsoft update', 'Windows 更新相关组件。'),
]

CAUTION = [
    (r'微信|wechat|企业微信|wecom', '含聊天记录、图片、文件缓存与登录状态，卸载后历史消息可能无法恢复。'),
    (r'wps office|kingsoft', '含文档模板、云同步配置、最近打开记录。'),
    (r'phpstudy', '⚠ 内含 MySQL / Apache / Nginx 数据目录，卸载可能带走本地数据库与网站文件，务必先备份 www 与 data 目录。'),
    (r'^git$|^git ', '含全局配置 .gitconfig、凭据管理器与 SSH 配置。'),
    (r'chrome|firefox|浏览器', '含书签、保存的密码、扩展与浏览历史；卸载时若勾选删除浏览数据将不可恢复。'),
    (r'charles', '含已安装的抓包根证书与代理配置，卸载后需手动信任清理残留证书。'),
    (r'todesk|向日葵|远控', '含设备授权与远程连接凭据，卸载后需重新授权。'),
    (r'网盘|netdisk|aliyun|quark|夸克|云盘|云电脑', '含本地同步缓存与账号登录态，缓存体积通常远大于程序中显示的占用。'),
    (r'输入法', '含个人词库与自定义短语。'),
    (r'github cli|gh ', '含 GitHub 登录凭据（keyring）。'),
    (r'剪映|美图|豆包|千问', '含用户作品缓存、素材库与账号数据。'),
    (r'迅雷|xunlei', '含下载任务记录、离线空间缓存与登录态。'),
    (r'文华|东方财富|期货|期货行情|交易', '含自选股 / 行情配置、交易账号登录信息与本地数据。'),
    (r'建设银行|网银|安全组件', '含网银数字证书与安全控件，卸载后需重新申请证书。'),
    (r'百度网盘', '含本地同步目录索引与上传队列，同步文件夹中的文件不会被删除，但需重新登录同步。'),
    (r'scan to', '扫描仪配套组件。'),
]

VENDOR_ALIAS = [
    ('tencent', ['Tencent', '腾讯']),
    ('baidu', ['Baidu', '百度', 'baidu']),
    ('kingsoft', ['Kingsoft', '金山', 'WPS', 'wps']),
    ('alibaba', ['Alibaba', '阿里', 'Taobao', 'aliyun']),
    ('chuntian', ['ByteDance', '字节', 'Doubao', '豆包']),
    ('xunlei', ['Xunlei', '迅雷', 'Thunder']),
    ('sogou', ['Sogou', '搜狗']),
    ('360', ['360', 'Qihoo', '奇虎']),
    ('meitu', ['Meitu', '美图']),
    ('youqu', ['ToDesk', 'YouQu', 'Hainan']),
    ('wenhua', ['文华', 'wh6', 'WH6', 'Wh6']),
    ('eastmoney', ['东方财富', 'EastMoney', 'eastmoney']),
    ('construction bank', ['CCB', 'China Construction Bank', '建行', 'E路护航']),
    ('nvidia', ['NVIDIA']),
    ('mozilla', ['Mozilla', 'Firefox']),
    ('google', ['Google', 'Chrome']),
    ('python software', ['Python']),
    ('node.js', ['Node.js', 'nodejs']),
    ('git development', ['Git']),
    ('dingtalk', ['DingTalk', '钉钉']),
    ('bytedance', ['ByteDance', '字节']),
    ('red hat', ['UsbDk']),
    ('hp', ['HP', 'Hewlett']),
    ('telecom', ['天翼', 'ctyun', 'Ctyun']),
    ('xiaomi', ['Xiaomi', '小米']),
    ('jianying', ['JianyingPro', '剪映']),
]

EXTRA_PATHS = {
    '微信': [r'%APPDATA%\Tencent\WeChat', r'%APPDATA%\Tencent\xwechat', r'%LOCALAPPDATA%\Tencent\WeChat',
             r'%LOCALAPPDATA%\Tencent\xwechat', r'%USERPROFILE%\Documents\xwechat_files',
             r'%USERPROFILE%\Documents\WeChat Files', r'%USERPROFILE%\AppData\Roaming\Tencent\WeChat'],
    '企业微信': [r'%APPDATA%\Tencent\WXWork', r'%LOCALAPPDATA%\Tencent\WXWork', r'%USERPROFILE%\Documents\WXWork'],
    '微信开发者工具': [r'%LOCALAPPDATA%\微信开发者工具', r'%APPDATA%\微信开发者工具', r'%USERPROFILE%\.wechat_devtools'],
    '百度网盘': [r'%LOCALAPPDATA%\BaiduNetdisk', r'%APPDATA%\Baidu\Netdisk', r'%USERPROFILE%\BaiduNetdiskDownload',
                 r'%APPDATA%\baidu\BaiduNetdisk'],
    '百度输入法': [r'%APPDATA%\Baidu\BaiduInput', r'%LOCALAPPDATA%\Baidu\BaiduInput'],
    '夸克': [r'%LOCALAPPDATA%\Quark', r'%APPDATA%\Quark', r'%APPDATA%\QuarkCloudDrive'],
    '阿里云盘': [r'%LOCALAPPDATA%\aDrive', r'%APPDATA%\aDrive'],
    '迅雷': [r'%APPDATA%\Thunder Network', r'%LOCALAPPDATA%\Thunder Network', r'%USERPROFILE%\Downloads\迅雷下载'],
    '美图秀秀': [r'%APPDATA%\Meitu', r'%LOCALAPPDATA%\Meitu'],
    '剪映专业版': [r'%LOCALAPPDATA%\JianyingPro', r'%APPDATA%\JianyingPro', r'%USERPROFILE%\AppData\Local\JianyingPro'],
    '豆包': [r'%LOCALAPPDATA%\Doubao', r'%APPDATA%\Doubao'],
    '豆包工作': [r'%LOCALAPPDATA%\Doubao', r'%APPDATA%\Doubao'],
    '千问办公': [r'%LOCALAPPDATA%\Qwen', r'%APPDATA%\Qwen'],
    'ToDesk': [r'%APPDATA%\ToDesk', r'%PROGRAMDATA%\ToDesk'],
    'Charles 5.2': [r'%APPDATA%\Charles'],
    'WPS Office 2023 专业版': [r'%LOCALAPPDATA%\Kingsoft', r'%APPDATA%\Kingsoft', r'%USERPROFILE%\AppData\Roaming\kingsoft'],
    'phpstudy集成环境': [r'%USERPROFILE%\phpstudy_pro', r'C:\phpstudy_pro', r'%PROGRAMDATA%\phpstudy_pro'],
    '360安全浏览器': [r'%LOCALAPPDATA%\360Chrome', r'%APPDATA%\360se6', r'%LOCALAPPDATA%\360se6'],
    'QQ浏览器': [r'%LOCALAPPDATA%\Tencent\QQBrowser', r'%APPDATA%\Tencent\QQBrowser'],
    '搜狗高速浏览器': [r'%APPDATA%\SogouExplorer', r'%LOCALAPPDATA%\SogouExplorer'],
    '东方财富期货': [r'%APPDATA%\EastMoney', r'%LOCALAPPDATA%\EastMoney'],
    '天翼云电脑': [r'%APPDATA%\Ctyun', r'%LOCALAPPDATA%\Ctyun', r'%PROGRAMDATA%\Ctyun'],
    'Bandizip': [r'%APPDATA%\Bandizip'],
    'Git': [r'%USERPROFILE%\.gitconfig', r'%USERPROFILE%\.git-credentials'],
    'Google Chrome': [r'%LOCALAPPDATA%\Google\Chrome', r'%PROGRAMFILES%\Google'],
    'Microsoft Edge': [r'%LOCALAPPDATA%\Microsoft\Edge'],
    'Mozilla Firefox (x64 zh-CN)': [r'%APPDATA%\Mozilla\Firefox', r'%LOCALAPPDATA%\Mozilla\Firefox'],
    'Microsoft Visual Studio Code (User)': [r'%APPDATA%\Code', r'%USERPROFILE%\.vscode'],
    'Microsoft OneDrive': [r'%LOCALAPPDATA%\Microsoft\OneDrive', r'%USERPROFILE%\OneDrive'],
    'GitHub CLI': [r'%APPDATA%\GitHub CLI', r'%LOCALAPPDATA%\GitHub CLI'],
    'dotnet': [r'%PROGRAMDATA%\dotnet'],
}

GENERIC_TOKENS = {
    'microsoft', 'corporation', 'corp', 'inc', 'ltd', 'co', 'limited', 'software', 'technology',
    'technologies', 'company', 'group', 'the', 'and', 'for', 'windows', 'win32', 'x64', 'x86',
    'edition', 'version', 'professional', 'pro', 'free', 'setup', 'installer', 'update', 'tool',
    'tools', 'utility', 'helper', 'service', 'agent', 'runtime', 'libraries', 'library', 'center',
    'user', 'module', 'modules', 'addon', 'add', 'redistributable', 'x', 'v14', 'bit', 'info',
    'online', 'network', 'tech', 'system', 'systems', 'data', 'file', 'files',
    'holding', 'shenzhen', 'beijing', 'shanghai', 'guangzhou', 'china',
    # 安装目录里常见的通用子目录名，单独作为令牌毫无区分度
    'application', 'applications', 'app', 'apps', 'client', 'desktop', 'web', 'core', 'bin',
    'current', 'program', 'programs', 'browser', 'main', 'launcher', 'support', 'resources',
    'assets', 'lib', 'libs', 'plugin', 'plugins', 'extension', 'extensions', 'cache', 'config',
    'settings', 'docs', 'source', 'build', 'release', 'stable', 'beta', 'portable', 'service',
    'server', 'binaries', 'package', 'packages', 'content', 'public', 'static', 'share',
    # 中文通用词
    '有限公司', '科技', '网络', '技术', '信息', '软件', '股份', '中心', '集团', '深圳', '北京', '上海',
    '广州', '专业版', '集成环境', '开发', '版本', '安全', '有限', '工具', '浏览器', '助手', '客户端',
    '模拟版', '实盘交易', '软件模拟版', '安全组件',
}

# 仅匹配到发行商目录时降级为「低可信」，因为该目录下通常堆着同一厂商的多个软件
VENDOR_TOKENS = set()
for _k, _alist in VENDOR_ALIAS:
    for _a in _alist:
        VENDOR_TOKENS.add(_a.lower())



def _risk_of(name, publisher):
    hay = (name or '') + ' ' + (publisher or '')
    low = hay.lower()
    for pat, why in DANGER:
        if re.search(pat, low, re.I):
            return 'danger', why
    for pat, why in CAUTION:
        if re.search(pat, hay, re.I):
            return 'caution', why
    return 'safe', '未发现系统依赖或用户数据风险，可正常卸载。'


def _tokens(name, publisher, install_loc):
    toks = set()

    def add(t):
        t = (t or '').strip().strip('.').strip()
        if len(t) < 2:
            return
        if t.lower() in GENERIC_TOKENS:
            return
        if re.fullmatch(r'[\d\.\-\+]+', t):
            return
        toks.add(t)

    clean = re.sub(r'[\(（][^)）]*[)）]', ' ', name or '')
    clean = re.sub(r'\b\d+(\.\d+)+\b', ' ', clean)
    clean = re.sub(r'\bv?\d+\.\d+.*$', ' ', clean)
    for t in re.split(r'[\s\-_/\\,，、。\.\+:：\|]+', clean):
        if re.search(r'[\u4e00-\u9fff]', t):
            if len(t) >= 2:
                add(t)
        elif len(t) >= 3:
            add(t)

    pub_low = (publisher or '').lower()
    name_low = (name or '').lower()
    for key, alist in VENDOR_ALIAS:
        if key.lower() in pub_low or key.lower() in name_low \
                or any(a.lower() in pub_low for a in alist) \
                or any(a.lower() in name_low for a in alist):
            for a in alist:
                add(a)

    for p in (install_loc or '').split(';'):
        p = p.strip().strip('"')
        if not p:
            continue
        b = os.path.basename(p.rstrip('\\/'))
        if b and len(b) >= 3:
            add(b)

    return sorted(toks)


def build_apps():
    """把扫描结果整理成面板数据（含风险分级、卸载方式判定、清理令牌）。"""
    raw = read_json(SCAN_JSON, None)
    if not raw:
        return None
    apps = []
    for r in raw.get('registry', []):
        risk, why = _risk_of(r['name'], r['publisher'])
        u = (r.get('uninstall') or '').strip()
        q = (r.get('quietUninstall') or '').strip()
        kind = r.get('kind') or 'none'
        silent_cmd, interactive_cmd = '', ''
        if kind == 'msi' and r.get('productCode'):
            silent_cmd = 'msiexec.exe /x %s /qn /norestart' % r['productCode']
            interactive_cmd = 'msiexec.exe /x %s /qb /norestart' % r['productCode']
        elif kind == 'exe' and (u or q):
            silent_cmd = q or ''
            interactive_cmd = u or q
            if not silent_cmd:
                b = os.path.basename(r.get('uninstallExe') or '').lower()
                if b.startswith('unins'):
                    silent_cmd = u + ' /VERYSILENT /NORESTART'
                elif b.startswith('uninst') or b.startswith('uninstall') or b.startswith('unins000'):
                    silent_cmd = u + ' /S'
        r2 = dict(r)
        r2.update({
            'risk': risk,
            'riskReason': why,
            'silentCmd': silent_cmd,
            'interactiveCmd': interactive_cmd,
            'tokens': _tokens(r['name'], r['publisher'], r.get('installLoc')),
            'category': 'desktop',
        })
        apps.append(r2)

    for a in raw.get('appx', []):
        label = a.get('displayName') or a['name']
        risk, why = _risk_of(label, a.get('publisher'))
        if not a.get('uninstallable'):
            risk = 'danger'
            why = '系统内置组件（NonRemovable），Windows 不允许卸载。'
        name_low = (label or '').lower()
        if re.search(r'store|商店|skype|画图|照片|计算器|terminal|terminal|记事本|notepad|截图|snipping|media player|相机|camera|地图|maps|天气|weather|邮件|mail|日历|calendar|人脉|people|反馈|feedback|tips|your phone|手机连接', name_low):
            if risk == 'safe':
                why = '系统预装应用，可安全移除（不影响系统运行，需要时可在商店重新安装）。'
        a2 = dict(a)
        a2.update({
            'name': label,
            'risk': risk,
            'riskReason': why,
            'silentCmd': a.get('uninstall') or '',
            'interactiveCmd': a.get('uninstall') or '',
            'tokens': _tokens(label, a.get('publisher'), a.get('installLoc')),
            'category': 'store',
        })
        apps.append(a2)

    env = {k: v for k, v in raw.items() if k not in ('registry', 'appx')}
    stats = {
        'total': len(apps),
        'desktop': sum(1 for a in apps if a['category'] == 'desktop'),
        'store': sum(1 for a in apps if a['category'] == 'store'),
        'uninstallable': sum(1 for a in apps if a.get('uninstallable')),
        'safe': sum(1 for a in apps if a['risk'] == 'safe' and a.get('uninstallable')),
        'caution': sum(1 for a in apps if a['risk'] == 'caution' and a.get('uninstallable')),
        'danger': sum(1 for a in apps if a['risk'] == 'danger' and a.get('uninstallable')),
        'system': sum(1 for a in apps if not a.get('uninstallable')),
    }
    try:
        import ctypes
        free = ctypes.c_ulonglong(0)
        ctypes.windll.kernel32.GetDiskFreeSpaceExW('C:\\', None, None, ctypes.byref(free))
        stats['freeGB'] = round(free.value / (1024 ** 3), 1)
    except Exception:
        stats['freeGB'] = 0
    return {'env': env, 'apps': apps, 'stats': stats, 'loadedAt': now_iso()}


# --------------------------------------------------------------------------
# 注册表快照 / 还原（自研，不依赖 reg.exe —— 该程序被本机安全策略禁用）
# --------------------------------------------------------------------------
import base64

REG_TYPES = {1: 'REG_SZ', 2: 'REG_EXPAND_SZ', 3: 'REG_BINARY', 4: 'REG_DWORD',
             5: 'REG_DWORD_BIG_ENDIAN', 7: 'REG_MULTI_SZ', 11: 'REG_QWORD'}


def _hive_of(prefix):
    return {'HKLM': winreg.HKEY_LOCAL_MACHINE, 'HKCU': winreg.HKEY_CURRENT_USER,
            'HKCR': winreg.HKEY_CLASSES_ROOT, 'HKU': winreg.HKEY_USERS}.get(prefix.upper())


def _enc_value(name, data, typ):
    if isinstance(data, bytes):
        return {'name': name, 'type': typ, 'typeName': REG_TYPES.get(typ, str(typ)),
                'kind': 'b64', 'data': base64.b64encode(data).decode('ascii')}
    if isinstance(data, (list, tuple)):
        return {'name': name, 'type': typ, 'typeName': REG_TYPES.get(typ, str(typ)),
                'kind': 'list', 'data': list(data)}
    return {'name': name, 'type': typ, 'typeName': REG_TYPES.get(typ, str(typ)),
            'kind': 'raw', 'data': data}


def dump_reg_key(key_path, limit=8000):
    """把一个注册表键（含子树）递归序列化成可还原的 JSON 结构。"""
    m = re.match(r'^(HKLM|HKCU|HKCR|HKU)\\(.+)$', key_path, re.I)
    if not m:
        return {'key': key_path, 'error': '无法解析的注册表路径（需以 HKLM\\ 或 HKCU\\ 开头）'}
    hive_name, sub = m.group(1).upper(), m.group(2)
    hive = _hive_of(hive_name)
    counter = {'n': 0, 'truncated': False}

    def walk(subpath):
        if counter['n'] >= limit:
            counter['truncated'] = True
            return None
        counter['n'] += 1
        node = {'key': subpath, 'values': [], 'subkeys': []}
        try:
            with winreg.OpenKey(hive, subpath, 0, winreg.KEY_READ) as k:
                i = 0
                while True:
                    try:
                        name, data, typ = winreg.EnumValue(k, i)
                    except OSError:
                        break
                    i += 1
                    node['values'].append(_enc_value(name, data, typ))
                j = 0
                while True:
                    try:
                        sk = winreg.EnumKey(k, j)
                    except OSError:
                        break
                    j += 1
                    child = walk(subpath + '\\' + sk)
                    if child is None:
                        break
                    node['subkeys'].append(child)
        except Exception as e:
            node['error'] = str(e)
        return node

    tree = walk(sub)
    return {'key': key_path, 'hive': hive_name, 'path': sub, 'tree': tree,
            'count': counter['n'], 'truncated': counter['truncated'], 'at': now_iso()}


def reg_snapshot(keys, label='snapshot'):
    """把若干注册表键快照为一个 JSON 文件，返回文件路径与统计。"""
    ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    f = os.path.join(BACKUP_DIR, 'regsnap_%s_%s.json' % (label, ts))
    items = []
    for k in keys:
        items.append(dump_reg_key(k))
    payload = {'at': now_iso(), 'label': label, 'keys': keys, 'items': items}
    write_json(f, payload)
    ok = sum(1 for i in items if not i.get('error'))
    return {'file': f, 'ok': ok, 'total': len(items), 'items': items, 'at': payload['at']}


def reg_restore(snapshot_file):
    """从 JSON 快照还原注册表。"""
    data = read_json(snapshot_file, None)
    if not data:
        return {'error': '快照文件无法读取：%s' % snapshot_file}
    restored, failed = [], []

    def build(hive, node):
        sub = node['key']
        vfail = []
        try:
            with winreg.CreateKeyEx(hive, sub, 0, winreg.KEY_WRITE | winreg.KEY_SET_VALUE) as k:
                for v in node.get('values', []):
                    try:
                        if v['kind'] == 'b64':
                            raw = base64.b64decode(v['data'])
                        elif v['kind'] == 'list':
                            raw = list(v['data'])          # REG_MULTI_SZ 必须传 list
                        else:
                            raw = v['data']
                        winreg.SetValueEx(k, v['name'], 0, v['type'], raw)
                    except Exception as ve:
                        vfail.append('%s: %s' % (v['name'], ve))
        except Exception as e:
            failed.append({'key': sub, 'error': str(e)})
            return
        if vfail:
            failed.append({'key': sub, 'error': '值写入失败 -> ' + '; '.join(vfail)})
        else:
            restored.append(sub)
        for c in node.get('subkeys', []):
            build(hive, c)

    for item in data.get('items', []):
        if item.get('error') or not item.get('tree'):
            failed.append({'key': item.get('key'), 'error': item.get('error') or '快照为空'})
            continue
        build(_hive_of(item['hive']), item['tree'])
    return {'restored': restored, 'failed': failed, 'file': snapshot_file}


# --------------------------------------------------------------------------
# 备份
# --------------------------------------------------------------------------
BACKUP_FILE = os.path.join(BACKUP_DIR, 'last_backup.json')
BACKUP_STATE = read_json(BACKUP_FILE, {}) or {}
BACKUP_STATE.setdefault('restorePoint', None)
BACKUP_STATE.setdefault('regExport', None)
BACKUP_STATE.setdefault('at', None)

BACKUP_PS = r'''
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$r = [ordered]@{ checkpoint='skipped'; enableSr='skipped'; points=@() }
try {
  Checkpoint-Computer -Description 'Before software uninstall (WorkBuddy panel)' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
  $r.checkpoint = 'ok'
} catch {
  $r.checkpoint = 'fail: ' + $_.Exception.Message
  if (Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue) {
    try {
      Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
      $r.enableSr = 'ok'
      try {
        Checkpoint-Computer -Description 'Before software uninstall (WorkBuddy panel)' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $r.checkpoint = 'ok-after-enable'
      } catch { $r.checkpoint = 'fail-after-enable: ' + $_.Exception.Message }
    } catch { $r.enableSr = 'fail: ' + $_.Exception.Message }
  } else { $r.enableSr = 'cmdlet-unavailable' }
}
try {
  $r.points = @(Get-ComputerRestorePoint | Select-Object -Last 5 | ForEach-Object { $_.Description + ' @ ' + $_.CreationTime })
} catch { $r.points = @('query-failed') }
[System.IO.File]::WriteAllText('__OUT__', ($r | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
'''


def do_backup(note=''):
    """1) 尝试创建系统还原点（必要时开启系统保护）2) 快照注册表 Uninstall 三处配置单元。"""
    res = ps_json(BACKUP_PS, 'backup', timeout=1800)
    info = res.get('data') if isinstance(res.get('data'), dict) else {}
    if not info:
        info = {'checkpoint': 'fail: ' + (res.get('stderr') or 'PowerShell 执行异常')[:400],
                'enableSr': 'unknown', 'points': []}
    snap = reg_snapshot([
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    ], label='before-uninstall')

    BACKUP_STATE['regExport'] = snap['file']
    BACKUP_STATE['at'] = now_iso()
    BACKUP_STATE['restorePoint'] = str(info.get('checkpoint', '')).startswith('ok')
    BACKUP_STATE['note'] = note
    BACKUP_STATE['snapshotKeys'] = snap['ok']
    BACKUP_STATE['text'] = info
    write_json(os.path.join(LOG_DIR, 'backup_%s.json' % datetime.datetime.now().strftime('%Y%m%d_%H%M%S')), info)
    write_json(BACKUP_FILE, {k: BACKUP_STATE.get(k) for k in
                             ('restorePoint', 'regExport', 'at', 'note', 'snapshotKeys')})
    return {'ok': True, 'regDir': snap['file'], 'restorePoint': BACKUP_STATE['restorePoint'],
            'snapshot': snap, 'info': info}


# --------------------------------------------------------------------------
# 卸载引擎
# --------------------------------------------------------------------------
JOBS = {}
JOBS_LOCK = threading.Lock()

PS_ENGINE = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$logPath = '__LOG__'
$jobPath = '__JOB__'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function W([string]$msg) {
  $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $msg
  [System.IO.File]::AppendAllText($logPath, $line + "`n", $utf8)
}
function Emit($obj) {
  [System.IO.File]::AppendAllText($logPath, '##RESULT##' + ($obj | ConvertTo-Json -Depth 5 -Compress) + "`n", $utf8)
}

$jobText = [System.IO.File]::ReadAllText($jobPath, $utf8)
$job = $jobText | ConvertFrom-Json
W ('JOB ' + $job.id + ' | mode=' + $job.mode + ' | ops=' + $job.operations.Count)

foreach ($op in $job.operations) {
  $ok = $false
  $detail = ''
  $skipped = $false
  W ''
  W ('=== ' + $op.name + '  [' + $op.kind + '] ===')
  try {
    if ($op.kind -eq 'msi') {
      if (-not $op.productCode) { throw 'no product code' }
      $args = if ($job.mode -eq 'silent') { @('/x', $op.productCode, '/qn', '/norestart') } else { @('/x', $op.productCode, '/qb', '/norestart') }
      W ('  msiexec ' + ($args -join ' '))
      $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
      W ('  exit=' + $p.ExitCode)
      if ($p.ExitCode -in @(0, 1641, 3010)) { $ok = $true }
      elseif ($p.ExitCode -eq 1605) { $ok = $true; $detail = 'product not installed (1605)' }
      elseif ($p.ExitCode -eq 1618) { $detail = 'another install in progress (1618), retry later' }
      else { $detail = 'msiexec exit=' + $p.ExitCode }
    }
    elseif ($op.kind -eq 'exe') {
      $exe = $op.exe
      $argString = $op.args
      if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { throw ('uninstaller not found: ' + $exe) }
      W ('  run: "' + $exe + '" ' + $argString)
      $p = Start-Process -FilePath $exe -ArgumentList $argString -Wait -PassThru
      W ('  exit=' + $p.ExitCode)
      $ok = $true
      if ($p.ExitCode -ne 0) { $detail = 'exit=' + $p.ExitCode + ' (uninstaller reported non-zero)' }
    }
    elseif ($op.kind -eq 'appx') {
      $pkg = $op.productCode
      W ('  Remove-AppxPackage ' + $pkg)
      Remove-AppxPackage -Package $pkg -ErrorAction Stop
      $ok = $true
      try {
        $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -eq ($pkg -split '_')[0] }
        if ($prov) { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null; W '  provisioned copy removed' }
      } catch { }
    }
    else {
      $skipped = $true
      $detail = 'no automated uninstaller available'
      W '  SKIP: no uninstaller'
    }
  } catch {
    $detail = $_.Exception.Message
    W ('  ERROR: ' + $detail)
  }

  # 卸载后核验
  if ($ok -and -not $skipped) {
    Start-Sleep -Milliseconds 800
    $stillThere = $false
    if ($op.kind -eq 'msi') {
      $stillThere = [bool](Get-ItemProperty -Path ("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" + $op.productCode) -ErrorAction SilentlyContinue)
    } elseif ($op.kind -eq 'appx') {
      $stillThere = [bool](Get-AppxPackage -Package $op.productCode -ErrorAction SilentlyContinue)
    } else {
      $stillThere = [bool](Get-ItemProperty -Path $op.regKey -ErrorAction SilentlyContinue)
    }
    W ('  verify: registry key gone = ' + (-not $stillThere))
    if ($stillThere) { $detail = ($detail + ' | 卸载后注册表项仍存在，可能需要重启或手动处理').Trim(' |') }
  }
  Emit ([ordered]@{ id=$op.id; name=$op.name; ok=$ok; skipped=$skipped; detail=$detail; kind=$op.kind })
}
W ''
W 'JOB FINISHED'
[System.IO.File]::AppendAllText($logPath, '##DONE##' + "`n", $utf8)
'''


def split_cmdline(cmd):
    cmd = (cmd or '').strip()
    if not cmd:
        return '', ''
    if cmd.startswith('"'):
        i = cmd.find('"', 1)
        if i > 0:
            return cmd[1:i], cmd[i + 1:].strip()
    m = re.match(r'^(\S+?\.exe)\s*(.*)$', cmd, re.I)
    if m:
        return m.group(1), m.group(2).strip()
    parts = cmd.split(' ', 1)
    return parts[0], (parts[1].strip() if len(parts) > 1 else '')


def build_operation(app, mode, override_cmd=None):
    """把面板条目转成引擎可执行的 operation。"""
    kind = app.get('kind')
    if app.get('source') == 'appx' or kind == 'appx':
        return {'id': app['id'], 'name': app['name'], 'kind': 'appx',
                'regKey': app.get('regRoot', ''), 'productCode': app.get('productCode')}
    mode = mode or 'silent'
    if kind == 'msi':
        return {'id': app['id'], 'name': app['name'], 'kind': 'msi',
                'regKey': _ps_reg_path(app.get('regRoot', '') + '\\' + app.get('regKey', '')),
                'productCode': app.get('productCode')}
    exe, args = '', ''
    if override_cmd:
        exe, args = split_cmdline(override_cmd)
    elif mode == 'silent':
        cmd = app.get('quietUninstall') or app.get('silentCmd') or ''
        exe, args = split_cmdline(cmd)
    if not exe:
        cmd = app.get('uninstall') or app.get('interactiveCmd') or ''
        exe, args = split_cmdline(cmd)
    return {'id': app['id'], 'name': app['name'], 'kind': 'exe', 'exe': exe, 'args': args,
            'regKey': _ps_reg_path(app.get('regRoot', '') + '\\' + app.get('regKey', '')), 'productCode': ''}


def start_job(operations, mode, kind_label='uninstall'):
    jid = datetime.datetime.now().strftime('%Y%m%d_%H%M%S') + '_' + uuid.uuid4().hex[:6]
    log_path = os.path.join(LOG_DIR, '%s_%s.log' % (kind_label, jid))
    open(log_path, 'w', encoding='utf-8').close()
    job_path = os.path.join(JOBS_DIR, '%s.json' % jid)
    payload = {'id': jid, 'mode': mode, 'operations': operations}
    write_json(job_path, payload)
    with JOBS_LOCK:
        JOBS[jid] = {'id': jid, 'status': 'running', 'createdAt': now_iso(),
                     'mode': mode, 'label': kind_label, 'logPath': log_path,
                     'results': [], 'total': len(operations),
                     'log': ['[queue] %d 项操作已入队，开始执行…' % len(operations)]}
    script = PS_ENGINE.replace('__LOG__', log_path).replace('__JOB__', job_path)
    sp = os.path.join(JOBS_DIR, '_run_%s.ps1' % jid)
    with open(sp, 'w', encoding='utf-8-sig') as f:
        f.write(script)

    def worker():
        try:
            p = subprocess.Popen(
                [PS_EXE, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', sp],
                creationflags=CREATE_NO_WINDOW)
            p.wait()
        finally:
            try:
                os.remove(sp)
            except Exception:
                pass
            with JOBS_LOCK:
                JOBS[jid]['status'] = 'done'

    threading.Thread(target=worker, daemon=True).start()
    return jid, log_path


def tail_job(jid):
    with JOBS_LOCK:
        job = JOBS.get(jid)
    if not job:
        return None
    try:
        with open(job['logPath'], 'r', encoding='utf-8', errors='replace') as f:
            raw = f.read().lstrip('\ufeff')
    except Exception:
        raw = ''
    lines, results, done = [], [], False
    for ln in raw.splitlines():
        if ln.startswith('##RESULT##'):
            try:
                results.append(json.loads(ln[len('##RESULT##'):]))
            except Exception:
                pass
        elif ln.startswith('##DONE##'):
            done = True
        else:
            lines.append(ln)
    return {'id': jid, 'status': 'done' if done else job['status'], 'mode': job['mode'],
            'label': job['label'], 'createdAt': job['createdAt'], 'total': job['total'],
            'log': lines, 'results': results, 'logFile': job['logPath']}


# --------------------------------------------------------------------------
# 残留扫描
# --------------------------------------------------------------------------
def _expand(p):
    return os.path.expandvars(p)


def _dir_size(path, budget_files=40000):
    total = 0
    n = 0
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        for fn in files:
            try:
                total += os.path.getsize(os.path.join(root, fn))
            except Exception:
                pass
            n += 1
            if n > budget_files:
                return total, n, True
    return total, n, False


def enum_reg_subkeys(hive, path, depth=1):
    """枚举注册表子键，返回带配置单元前缀的完整路径，如 HKLM\\SOFTWARE\\Quark。"""
    out = []
    hmap = {'HKLM': winreg.HKEY_LOCAL_MACHINE, 'HKCU': winreg.HKEY_CURRENT_USER}
    h = hmap.get(hive)
    if h is None:
        return out

    def walk(p, d):
        try:
            with winreg.OpenKey(h, p, 0, winreg.KEY_READ) as k:
                i = 0
                while True:
                    try:
                        sub = winreg.EnumKey(k, i)
                    except OSError:
                        break
                    i += 1
                    full = p + '\\' + sub
                    out.append(hive + '\\' + full)
                    if d > 1:
                        walk(full, d - 1)
        except Exception:
            pass

    walk(path, depth)
    return out


REG_ROOTS = [
    ('HKLM', r'SOFTWARE', 1),
    ('HKLM', r'SOFTWARE\WOW6432Node', 1),
    ('HKCU', r'SOFTWARE', 1),
]


def _eff_len(tok):
    """有效长度：中日韩字符按 2 计，ASCII 按 1 计，避免「微信」这类短词压过「微信开发者工具」。"""
    return sum(2 if '\u4e00' <= ch <= '\u9fff' else 1 for ch in tok)


LEGACY_JUNCTIONS = {
    'application data', 'history', 'temporary internet files', 'local settings',
    'my documents', 'nethood', 'printhood', 'recent', 'sendto', 'start menu',
    'templates', 'cookies', 'documents and settings', 'cache',
}


def _is_reparse(path):
    """判断是否为目录联接 / 符号链接（AppData 下的 'Application Data' 等会造成无限环路）。"""
    try:
        st = os.stat(path, follow_symlinks=False)
        return bool(getattr(st, 'st_file_attributes', 0) & 0x400)
    except Exception:
        return False


def _all_tokens(apps):
    """全量令牌表，用于判定一个残留目录「更像属于哪个软件」。"""
    out = []
    for a in apps:
        if not a.get('uninstallable'):
            continue
        for tok in (a.get('tokens') or []):
            if _eff_len(tok) >= 4:
                out.append({'tok': tok, 'low': tok.lower(), 'eff': _eff_len(tok),
                            'name': a['name'], 'id': a['id']})
    return out


def _best_owner(basename, all_tokens):
    bl = basename.lower()
    best = None
    for t in all_tokens:
        if t['low'] in bl:
            if best is None or t['eff'] > best['eff']:
                best = t
    return best


FALSE_POSITIVE_DIRS = re.compile(r'^the .+ authors$|^\.', re.I)


def _is_false_positive(basename):
    return bool(FALSE_POSITIVE_DIRS.match(basename))


def scan_leftover(app_ids):
    """扫描指定软件的残留：文件目录 + 注册表项。只读，不做任何删除。"""
    data = build_apps()
    if not data:
        return {'error': 'scan data missing'}
    by_id = {a['id']: a for a in data['apps']}
    targets = [by_id[i] for i in app_ids if i in by_id]
    all_tokens = _all_tokens(data['apps'])

    # 1. 注册表全量枚举一次，之后做匹配
    reg_index = []
    for hive, path, depth in REG_ROOTS:
        for full in enum_reg_subkeys(hive, path, depth):
            reg_index.append(full)

    file_roots = [
        (_env['PROGRAMFILES'], 2),
        (_env['PROGRAMFILES_X86'], 2),
        (_env['PROGRAMDATA'], 2),
        (_env['LOCALAPPDATA'], 2),
        (_env['APPDATA'], 2),
        (os.path.join(_env['LOCALAPPDATA'], 'Programs'), 1),
    ]
    SKIP_DIRS = {'microsoft', 'windows', 'packages', 'temp', 'winsxs', 'google', 'mozilla',
                 'common files', 'internet explorer', 'windowsapps', 'nvidia corporation'}
    file_index = []
    seen_real = set()

    def push(p):
        try:
            rp = os.path.realpath(p).lower()
        except Exception:
            rp = p.lower()
        if rp in seen_real:
            return
        seen_real.add(rp)
        file_index.append(p)

    for r, depth in file_roots:
        if not r or not os.path.isdir(r):
            continue
        r = r.rstrip('\\')
        try:
            level1 = list(os.scandir(r))
        except Exception:
            continue
        for e1 in level1:
            if not e1.is_dir(follow_symlinks=False):
                continue
            if e1.name.lower() in LEGACY_JUNCTIONS or _is_reparse(e1.path):
                continue
            push(e1.path)
            if depth >= 2 and e1.name.lower() not in SKIP_DIRS:
                try:
                    for e2 in os.scandir(e1.path):
                        if not e2.is_dir(follow_symlinks=False):
                            continue
                        if e2.name.lower() in LEGACY_JUNCTIONS or _is_reparse(e2.path):
                            continue
                        push(e2.path)
                except Exception:
                    pass

    out = []
    for t in targets:
        toks = [x for x in (t.get('tokens') or []) if _eff_len(x) >= 4]
        files, regs = [], []

        def add_file(path, why, conf):
            if not any(f['path'].lower() == path.lower() for f in files):
                files.append({'path': path, 'why': why, 'conf': conf})

        def add_reg(path, why, conf):
            if not any(g['path'].lower() == path.lower() for g in regs):
                regs.append({'path': path, 'why': why, 'conf': conf})

        # 应用自身安装目录（最高可信度）
        for p in (t.get('installLoc') or '').replace('"', '').split(';'):
            p = p.strip()
            if p and os.path.isdir(p):
                add_file(p, '注册表中记录的安装目录', 'high')

        for path in file_index:
            base = os.path.basename(path)
            if _is_false_positive(base):
                continue
            blow = base.lower()
            hit, hit_eff = None, 0
            for tok in toks:
                if len(tok) >= 4 and tok.lower() in blow:
                    if _eff_len(tok) > hit_eff:
                        hit, hit_eff = tok, _eff_len(tok)
                elif blow == tok.lower():
                    hit, hit_eff = tok, _eff_len(tok)
            if not hit:
                continue
            # 归属判定：这个目录是否更像属于另一个已安装软件？
            owner = _best_owner(base, all_tokens)
            conf, why = 'mid', '目录名匹配「%s」' % hit
            if hit.lower() in VENDOR_TOKENS:
                conf = 'low'
                why = '仅匹配到发行商名「%s」，该目录下可能同时存放该厂商的其他软件' % hit
            if owner and owner['id'] != t['id'] and owner['eff'] > hit_eff:
                conf = 'low'
                why = '目录名匹配「%s」，但更像属于「%s」' % (hit, owner['name'])
            if owner and owner['id'] == t['id'] and owner['eff'] > hit_eff:
                conf, why = 'high', '目录名匹配「%s」' % owner['tok']
            add_file(path, why, conf)

        for p in EXTRA_PATHS.get(t['name'], []):
            ep = _expand(p)
            if os.path.exists(ep):
                add_file(ep, '已知%s残留位置' % t['name'], 'high')

        # 厂商目录扇出：<根目录>\<厂商>\ 的下级，归属靠推测，一律低可信
        for tok in toks:
            if tok.lower() not in VENDOR_TOKENS:
                continue
            for root in (_env['PROGRAMFILES'], _env['PROGRAMFILES_X86'], _env['PROGRAMDATA'],
                         _env['LOCALAPPDATA'], _env['APPDATA']):
                if not root:
                    continue
                d1 = os.path.join(root, tok)
                if not os.path.isdir(d1):
                    continue
                try:
                    for ch in os.scandir(d1):
                        if ch.is_dir(follow_symlinks=False) and ch.name.lower() not in LEGACY_JUNCTIONS \
                                and not _is_reparse(ch.path):
                            add_file(ch.path, '位于发行商「%s」目录下，推测属于本软件' % tok, 'low')
                except Exception:
                    pass

        for full in reg_index:
            leaf = full.rsplit('\\', 1)[-1]
            leaf_low = leaf.lower()
            hit, hit_eff = None, 0
            for tok in toks:
                if tok.lower() in leaf_low and _eff_len(tok) > hit_eff:
                    hit, hit_eff = tok, _eff_len(tok)
            if not hit:
                continue
            owner = _best_owner(leaf, all_tokens)
            conf, why = 'mid', '键名匹配「%s」' % hit
            if hit.lower() in VENDOR_TOKENS:
                conf = 'low'
                why = '仅匹配到发行商名「%s」，该键下可能同时存放该厂商的其他软件' % hit
            if owner and owner['id'] != t['id'] and owner['eff'] > hit_eff:
                conf = 'low'
                why = '键名匹配「%s」，但更像属于「%s」' % (hit, owner['name'])
            add_reg(full, why, conf)

        # 厂商注册表扇出：HKLM\SOFTWARE\<厂商>\ 的下级
        for tok in toks:
            if tok.lower() not in VENDOR_TOKENS:
                continue
            for hive in ('HKLM', 'HKCU'):
                for base in (r'SOFTWARE', r'SOFTWARE\WOW6432Node'):
                    for k in enum_reg_subkeys(hive, base + '\\' + tok, 1):
                        add_reg(k, '位于发行商「%s」注册表目录下，推测属于本软件' % tok, 'low')

        # 去重 + 去掉父路径已被包含的子路径
        files = _dedupe_paths(files)
        regs = _dedupe_paths(regs)
        out.append({'id': t['id'], 'name': t['name'], 'tokens': [x for x in (t.get('tokens') or [])],
                    'files': files, 'regs': regs, 'installLoc': t.get('installLoc') or ''})
    return {'items': out, 'scannedAt': now_iso()}


def _dedupe_paths(items):
    items = sorted(items, key=lambda x: len(x['path']))
    kept = []
    for it in items:
        low = it['path'].lower().rstrip('\\')
        dup = False
        for k in kept:
            klow = k['path'].lower().rstrip('\\')
            if low == klow or low.startswith(klow + '\\'):
                dup = True
                break
        if not dup:
            kept.append(it)
    return kept


def size_paths(paths):
    out = {}
    for p in paths:
        if os.path.isdir(p):
            sz, n, capped = _dir_size(p)
            out[p] = {'bytes': sz, 'files': n, 'capped': capped}
        elif os.path.isfile(p):
            try:
                out[p] = {'bytes': os.path.getsize(p), 'files': 1, 'capped': False}
            except Exception:
                out[p] = {'bytes': 0, 'files': 0, 'capped': False}
        else:
            out[p] = {'bytes': 0, 'files': 0, 'capped': False, 'missing': True}
    return out


# --------------------------------------------------------------------------
# 隔离区（残留文件的"回收站式"处理，可还原）
# --------------------------------------------------------------------------
MANIFEST = os.path.join(QUAR_DIR, 'manifest.json')


def _ps_delete_reg_keys(keys):
    """用 PowerShell 注册表提供程序删除键（不使用被禁用的 reg.exe）。"""
    script = r'''
$ErrorActionPreference='Continue'
$list = __LIST__
$out = @()
foreach ($k in $list) {
  $ps = $k -replace '^HKLM', 'HKLM:' -replace '^HKCU', 'HKCU:' -replace '^HKCR', 'HKCR:' -replace '^HKU', 'HKU:'
  try {
    if (Test-Path -LiteralPath $ps) {
      Remove-Item -LiteralPath $ps -Recurse -Force -ErrorAction Stop
      $out += ('DELETED|' + $k)
    } else { $out += ('MISSING|' + $k) }
  } catch { $out += ('FAIL|' + $k + '|' + $_.Exception.Message) }
}
[System.IO.File]::WriteAllText('__OUT__', ($out | ConvertTo-Json -Depth 3 -Compress), (New-Object System.Text.UTF8Encoding($false)))
'''
    script = script.replace('__LIST__', ps_literal_list(keys))
    res = ps_json(script, 'regdel', timeout=900)
    data = res.get('data')
    if isinstance(data, str):
        data = [data]
    return data if isinstance(data, list) else []


def quarantine(paths, regkeys):
    """把残留文件移动到隔离区、注册表项快照后删除。全部可还原。"""
    ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    box = os.path.join(QUAR_DIR, ts)
    os.makedirs(box, exist_ok=True)
    man = read_json(MANIFEST, []) or []
    entry = {'batch': ts, 'at': now_iso(), 'box': box, 'files': [], 'regs': []}

    for i, p in enumerate(paths):
        if not os.path.exists(p):
            entry['files'].append({'src': p, 'dest': None, 'status': 'missing'})
            continue
        base = os.path.basename(p.rstrip('\\')) or ('item_%d' % i)
        dest = os.path.join(box, '%02d_%s' % (i, base))
        try:
            is_dir = os.path.isdir(p)
            shutil.move(p, dest)
            entry['files'].append({'src': p, 'dest': dest, 'status': 'moved', 'isDir': is_dir})
        except Exception as e:
            entry['files'].append({'src': p, 'dest': None, 'status': 'failed', 'error': str(e)})

    if regkeys:
        # 先做可还原快照，再删除
        snap = reg_snapshot(regkeys, label='quarantine_' + ts)
        snap_dest = os.path.join(box, 'registry_snapshot.json')
        try:
            shutil.move(snap['file'], snap_dest)
        except Exception:
            snap_dest = snap['file']
        entry['regSnapshot'] = snap_dest
        results = _ps_delete_reg_keys(regkeys)
        for line in results:
            parts = str(line).split('|')
            st = parts[0] if parts else 'FAIL'
            key = parts[1] if len(parts) > 1 else ''
            entry['regs'].append({'key': key, 'status': st,
                                  'error': parts[2] if len(parts) > 2 else ''})

    man.append(entry)
    write_json(MANIFEST, man)
    return {'ok': True, 'batch': ts, 'entry': entry}


def purge_to_recycle(paths):
    """把隔离区里的东西送进回收站（可再恢复一次）。"""
    script = r'''
$ErrorActionPreference='Continue'
Add-Type -AssemblyName Microsoft.VisualBasic
$list = __LIST__
$out = @()
foreach ($p in $list) {
  try {
    if (-not (Test-Path -LiteralPath $p)) { $out += ('MISSING|' + $p); continue }
    if ((Get-Item -LiteralPath $p).PSIsContainer) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p,'OnlyErrorDialogs','SendToRecycleBin')
    } else {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p,'OnlyErrorDialogs','SendToRecycleBin')
    }
    $out += ('RECYCLED|' + $p)
  } catch { $out += ('FAIL|' + $p + '|' + $_.Exception.Message) }
}
[System.IO.File]::WriteAllText('__OUT__', ($out | ConvertTo-Json -Depth 3 -Compress), (New-Object System.Text.UTF8Encoding($false)))
'''
    script = script.replace('__LIST__', ps_literal_list(paths))
    res = ps_json(script, 'purge', timeout=1200)
    data = res.get('data')
    if isinstance(data, str):
        data = [data]
    if not isinstance(data, list):
        data = []
    return {'results': data}


def restore_quarantine(dests):
    man = read_json(MANIFEST, []) or []
    restored, failed = [], []
    for entry in man:
        for f in entry['files']:
            if f.get('dest') in dests and f.get('status') == 'moved':
                try:
                    if os.path.exists(f['src']):
                        failed.append({'dest': f['dest'], 'error': '目标已存在，跳过'})
                        continue
                    os.makedirs(os.path.dirname(f['src']), exist_ok=True)
                    shutil.move(f['dest'], f['src'])
                    f['status'] = 'restored'
                    restored.append(f['src'])
                except Exception as e:
                    failed.append({'dest': f['dest'], 'error': str(e)})
    write_json(MANIFEST, man)
    return {'restored': restored, 'failed': failed}


def purge_quarantine_empty():
    """清空隔离区中已被移走/还原的空目录。"""
    for name in os.listdir(QUAR_DIR):
        p = os.path.join(QUAR_DIR, name)
        if os.path.isdir(p) and not os.listdir(p):
            try:
                os.rmdir(p)
            except Exception:
                pass
    return True


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
_cache = {'apps': None}


def get_apps(force=False):
    if force or not _cache['apps']:
        _cache['apps'] = build_apps()
    return _cache['apps']


class Handler(BaseHTTPRequestHandler):
    server_version = 'UninstallPanel/1.0'

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype='application/json; charset=utf-8'):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path in ('/', '/index.html'):
                with open(os.path.join(BASE, 'index.html'), 'rb') as f:
                    return self._send(200, f.read(), 'text/html; charset=utf-8')
            if u.path == '/api/state':
                data = get_apps(True)
                data['backup'] = {'restorePoint': BACKUP_STATE.get('restorePoint'),
                                  'at': BACKUP_STATE.get('at'),
                                  'regDir': BACKUP_STATE.get('regExport')}
                data['elevated'] = is_elevated()
                return self._send(200, data)
            if u.path == '/api/job':
                jid = q.get('id', [''])[0]
                tail = tail_job(jid)
                if not tail:
                    return self._send(404, {'error': 'job not found'})
                return self._send(200, tail)
            if u.path == '/api/quarantine':
                return self._send(200, {'manifest': read_json(MANIFEST, []) or [],
                                        'dir': QUAR_DIR})
            if u.path == '/api/snapshots':
                return self._send(200, list_snapshots())
            if u.path == '/api/log':
                f = q.get('file', [''])[0]
                if os.path.isfile(f) and os.path.abspath(f).startswith(os.path.abspath(LOG_DIR)):
                    with open(f, 'r', encoding='utf-8', errors='replace') as fh:
                        return self._send(200, {'text': fh.read()})
                return self._send(404, {'error': 'log not found'})
            return self._send(404, {'error': 'not found'})
        except Exception:
            return self._send(500, {'error': traceback.format_exc()})

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b'{}'
        try:
            payload = json.loads(raw.decode('utf-8') or '{}')
        except Exception:
            payload = {}
        try:
            if u.path == '/api/rescan':
                _cache['apps'] = None
                return self._send(200, {'ok': True, 'apps': get_apps(True)})

            if u.path == '/api/backup':
                return self._send(200, do_backup(payload.get('note', '')))

            if u.path == '/api/preview':
                data = get_apps()
                by_id = {a['id']: a for a in data['apps']}
                mode = payload.get('mode', 'silent')
                steps = []
                for i in payload.get('ids', []):
                    a = by_id.get(i)
                    if not a:
                        continue
                    op = build_operation(a, mode, (payload.get('overrides') or {}).get(i))
                    if op['kind'] == 'msi':
                        cmd = 'msiexec.exe /x %s %s /norestart' % (
                            op['productCode'], '/qn' if mode == 'silent' else '/qb')
                    elif op['kind'] == 'appx':
                        cmd = 'Remove-AppxPackage -Package "%s"' % op['productCode']
                    else:
                        cmd = '"%s" %s' % (op['exe'], op['args'])
                    steps.append({'id': a['id'], 'name': a['name'], 'risk': a['risk'],
                                  'kind': op['kind'], 'cmd': cmd,
                                  'riskReason': a['riskReason'],
                                  'note': a.get('blocker') or ''})
                return self._send(200, {'steps': steps})

            if u.path == '/api/uninstall':
                ids = payload.get('ids', [])
                if payload.get('confirm') != 'UNINSTALL':
                    return self._send(400, {'error': '缺少确认令牌'})
                if len(ids) > 10:
                    return self._send(400, {'error': '单批最多 10 项，请分批执行（安全护栏）'})
                if not ids:
                    return self._send(400, {'error': '未选择任何软件'})
                if not BACKUP_STATE.get('at'):
                    return self._send(400, {'error': '请先执行「系统备份」，需创建还原点并导出注册表'})
                data = get_apps()
                by_id = {a['id']: a for a in data['apps']}
                mode = payload.get('mode', 'silent')
                overrides = payload.get('overrides') or {}
                ops, blocked = [], []
                for i in ids:
                    a = by_id.get(i)
                    if not a:
                        continue
                    if not a.get('uninstallable'):
                        blocked.append({'name': a['name'], 'why': a['riskReason']})
                        continue
                    ops.append(build_operation(a, mode, overrides.get(i)))
                if not ops:
                    return self._send(400, {'error': '所选项目均不可自动卸载', 'blocked': blocked})
                # 执行前逐一快照这些软件的注册表键，作为精确回滚点
                snap_keys = []
                for a in [by_id[i] for i in ids if i in by_id]:
                    if a.get('source') == 'appx' or a.get('kind') == 'appx':
                        continue
                    k = (a.get('regRoot') or '') + '\\' + (a.get('regKey') or '')
                    if k.strip('\\') and re.match(r'^(HKLM|HKCU)\\', k):
                        snap_keys.append(k)
                prec = None
                if snap_keys:
                    try:
                        s = reg_snapshot(snap_keys, label='pre-uninstall')
                        prec = {'file': s['file'], 'ok': s['ok'], 'total': s['total']}
                    except Exception as e:
                        prec = {'error': str(e)}
                jid, lp = start_job(ops, mode, 'uninstall')
                return self._send(200, {'ok': True, 'jobId': jid, 'count': len(ops),
                                        'blocked': blocked, 'presnapshot': prec})

            if u.path == '/api/snapshot':
                return self._send(200, reg_snapshot(payload.get('keys', []),
                                                    payload.get('label', 'manual')))

            if u.path == '/api/reg-restore':
                done, failed = [], []
                for f in payload.get('files', []):
                    ap = os.path.abspath(f)
                    if not ap.startswith(os.path.abspath(BACKUP_DIR)) and \
                       not ap.startswith(os.path.abspath(QUAR_DIR)):
                        failed.append({'file': f, 'error': '只允许还原本工具自己生成的快照'})
                        continue
                    r = reg_restore(ap)
                    done.extend(r.get('restored', []))
                    failed.extend(r.get('failed', []))
                return self._send(200, {'restored': done, 'failed': failed})

            if u.path == '/api/leftover':
                return self._send(200, scan_leftover(payload.get('ids', [])))

            if u.path == '/api/size':
                return self._send(200, {'sizes': size_paths(payload.get('paths', []))})

            if u.path == '/api/open':
                p = payload.get('path', '')
                if os.path.exists(p):
                    subprocess.Popen(['explorer', os.path.normpath(p)])
                    return self._send(200, {'ok': True})
                return self._send(404, {'error': '路径不存在：%s' % p})

            if u.path == '/api/quarantine':
                return self._send(200, quarantine(payload.get('paths', []), payload.get('regkeys', [])))

            if u.path == '/api/purge':
                return self._send(200, purge_to_recycle(payload.get('paths', [])))

            if u.path == '/api/restore':
                return self._send(200, restore_quarantine(payload.get('dests', [])))

            if u.path == '/api/quarantine/cleanup':
                return self._send(200, {'ok': purge_quarantine_empty()})

            return self._send(404, {'error': 'not found'})
        except Exception:
            return self._send(500, {'error': traceback.format_exc()})


def list_snapshots():
    out = []
    for d, kind in ((BACKUP_DIR, 'backup'), (QUAR_DIR, 'quarantine')):
        for dirpath, _dirs, files in os.walk(d):
            for fn in files:
                if fn.endswith('.json') and ('regsnap' in fn or 'registry_snapshot' in fn):
                    fp = os.path.join(dirpath, fn)
                    meta = read_json(fp, {}) or {}
                    out.append({'file': fp, 'kind': kind, 'at': meta.get('at'),
                                'label': meta.get('label'), 'keys': len(meta.get('items', []))})
    out.sort(key=lambda x: str(x.get('at') or ''), reverse=True)
    return {'snapshots': out}


def is_elevated():
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def find_port(start=PORT):
    for p in range(start, start + 40):
        s = socket.socket()
        try:
            s.bind(('127.0.0.1', p))
            s.close()
            return p
        except OSError:
            continue
    return start


def main():
    if not os.path.exists(SCAN_JSON):
        print('ERROR: 缺少扫描数据 %s，请先运行扫描。' % SCAN_JSON)
        sys.exit(1)
    port = find_port()
    srv = HTTPServer(('127.0.0.1', port), Handler)
    info = {
        'port': port,
        'url': 'http://127.0.0.1:%d/' % port,
        'elevated': is_elevated(),
        'pid': os.getpid(),
        'startedAt': now_iso(),
    }
    write_json(os.path.join(BASE, 'panel.info.json'), info)
    print('PANEL_READY http://127.0.0.1:%d/  elevated=%s' % (port, info['elevated']), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
