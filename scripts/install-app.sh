#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
python3 - "$PWD/dist/AI落地安全检测.app" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1])
target = Path.home() / 'Applications/AI落地安全检测.app'
legacy_names = ('Network Watch.app', 'Claude落地IP检测.app', 'claude落地IP检测.app')
legacy_targets = [target.with_name(name) for name in legacy_names]
legacy_sources = [source.with_name(name) for name in legacy_names]
target.parent.mkdir(exist_ok=True)
# 更名时同时识别旧安装路径，避免两个后台检测实例并行运行。
pids = subprocess.run(['/usr/bin/pgrep', '-x', 'NetworkWatch'], capture_output=True, text=True)
for value in pids.stdout.split():
    actual = subprocess.run(['/bin/ps', '-p', value, '-o', 'comm='], capture_output=True, text=True).stdout.strip()
    if actual not in {str(path / 'Contents/MacOS/NetworkWatch') for path in (target, *legacy_targets)}:
        continue
    pid = int(value)
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        continue
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        raise SystemExit('旧应用仍在退出中，安装未覆盖，请稍后重试。')

register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
for previous in (target, *legacy_targets, *legacy_sources):
    if not previous.exists():
        continue
    # macOS 默认文件系统不区分大小写，旧小写路径可能就是本次构建包。
    if previous.samefile(source):
        continue
    if previous != target:
        result = subprocess.run([register, '-u', str(previous)], capture_output=True, text=True)
        if result.returncode and '-10814' not in result.stdout + result.stderr:
            raise SystemExit('无法注销旧名称：' + result.stdout + result.stderr)
    backup = Path(tempfile.mkdtemp(prefix='network-watch-backup-')) / 'NetworkWatch.backup'
    previous.rename(backup)
    print('旧安装或构建已保留：', backup)
subprocess.run(['/usr/bin/ditto', str(source), str(target)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(target)], check=True)
# 替换包内资源不一定更新 .app 目录时间戳；IconServices 会因此继续使用旧缓存。
os.utime(target, None)
# 通知按 bundle ID 查找资源，避免旧开发产物留下无图标的重复注册。
unregister = subprocess.run([register, '-u', str(source)], capture_output=True, text=True)
# -10814 表示该构建产物已不在注册表中，重复安装时属于正常情况。
if unregister.returncode and '-10814' not in unregister.stdout + unregister.stderr:
    raise SystemExit('无法注销旧开发产物：' + unregister.stdout + unregister.stderr)
subprocess.run([register, '-f', str(target)], check=True)
subprocess.run(['/usr/bin/open', str(target), '--args', '--show-window'], check=True)
print('已安装并刷新应用注册：', target)
PY
