# -*- coding: utf-8 -*-
"""把引擎分片 + 内嵌界面组装成单文件便携脚本（UTF-8 BOM，供 PowerShell 5.1 正确解析中文）。

用法：cd portable && python build.py
输出：portable/UninstallPanel.ps1 与 portable/启动面板.bat
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PARTS = [
    'src/p1_scan_engine.ps1',
    'src/p2_uninstall_job.ps1',
    'src/p3_backup_cleanup.ps1',
    'src/p4_http_server.ps1',
]
HTML = os.path.join(ROOT, 'uninstall-panel', 'index.html')
OUT = os.path.join(HERE, 'UninstallPanel.ps1')

BAT = r'''@echo off
title Uninstall Panel - Portable Edition
rem  Panel: http://127.0.0.1:8791/   Close this window to stop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UninstallPanel.ps1"
if errorlevel 1 pause
'''


def main():
    html = open(HTML, encoding='utf-8').read()
    if "'@" in html:
        sys.exit('ERROR: 界面文件里出现了 PowerShell here-string 结束符，需要转义处理')
    src = ''
    for p in PARTS:
        with open(os.path.join(HERE, p), encoding='utf-8') as f:
            src += f.read().rstrip() + '\n\n'
    src = src.replace('@@HTML@@', html)
    with open(OUT, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        f.write(src)

    bat = os.path.join(HERE, '启动面板.bat')
    with open(bat, 'w', encoding='ascii', newline='\r\n') as f:
        f.write(BAT)

    print('OK  %s  (%.1f KB, %d lines)' % (OUT, os.path.getsize(OUT) / 1024.0, src.count('\n') + 1))
    print('OK  %s' % bat)


if __name__ == '__main__':
    main()
