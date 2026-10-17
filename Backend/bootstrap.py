"""User-initiated temporary-copy key bootstrap. Never quits current WeChat or alters original/SIP.
Requires explicit UI acknowledgement, original already quit, and exact selected account.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess as sp
import sys
import tempfile


def emit(text): print(json.dumps({'status': text}, ensure_ascii=False), flush=True)

def run(args):
    value = sp.run(args, stdout=sp.PIPE, stderr=sp.PIPE)
    if value.returncode: raise RuntimeError('external_tool_failed')
    return value.stdout+value.stderr


def main():
    if len(sys.argv) != 5 or sys.argv[1] != '--acknowledge-copy': raise RuntimeError('acknowledgement_required')
    root = Path(sys.argv[2]).resolve(strict=True)
    account = hashlib.sha256(str(root).encode()).hexdigest()
    app_exe = Path(sys.argv[3]).resolve(strict=True)
    work = Path(sys.argv[4]).resolve(strict=True)
    if root.name != 'db_storage' or not list(root.rglob('*.db')): raise RuntimeError('no_account_database')
    if platform.machine() != 'arm64' or os.geteuid() == 0: raise RuntimeError('native_arm64_no_root_required')
    if sp.run(['/usr/bin/pgrep','-x','WeChat'], stdout=sp.DEVNULL).returncode == 0:
        raise RuntimeError('quit_wechat_yourself_first')
    original = Path('/Applications/WeChat.app')
    info = plistlib.loads((original/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != '4.1.15': raise RuntimeError('unsupported_wechat_version')
    signature = run(['/usr/bin/codesign','-dvv',str(original)])
    run(['/usr/bin/codesign','--verify','--deep','--strict',str(original)])
    pythonpath = run(['/usr/bin/xcrun','lldb','-P']).decode().strip()
    emit('正在准备一次性副本；原版签名和 SIP 保持不变。')
    with tempfile.TemporaryDirectory(prefix='wechat-bootstrap-', dir=str(work)) as folder:
        os.chmod(folder, 0o700)
        trial = Path(folder)/'WeChat-Setup.app'
        run(['/usr/bin/ditto',str(original),str(trial)])
        # Do not carry original entitlements/private allowances into our unsigned debugging copy.
        run(['/usr/bin/codesign','--force','--deep','--sign','-',str(trial)])
        run(['/usr/bin/codesign','--verify','--deep','--strict',str(trial)])
        emit('临时微信将打开。请仅登录本人的目标账号；可能需要手机确认。不要在副本中编辑草稿或聊天。最多等待 180 秒。')
        env = dict(os.environ, PYTHONPATH=pythonpath)
        try:
            rc = sp.call(['/usr/bin/python3',str(Path(__file__).with_name('capture_keys.py')),
                '--exe',str(trial/'Contents/MacOS/WeChat'),'--db-root',str(root),
                '--key-writer',str(app_exe),'--account',account,'--timeout','180'],env=env)
        finally:
            if run(['/usr/bin/codesign','-dvv',str(original)]) != signature: raise RuntimeError('original_signature_changed')
            register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
            sp.run([register,'-u',str(trial)], stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        emit('副本流程结束；已核对原版签名未变。请自行打开 /Applications/WeChat.app。未自动重启原版。')
        return rc

if __name__ == '__main__':
    os.umask(0o077)
    try: result = main()
    except Exception as error:
        # Fixed diagnostic codes only.
        allowed={'quit_wechat_yourself_first','unsupported_wechat_version','no_account_database','native_arm64_no_root_required','original_signature_changed'}
        emit(str(error) if str(error) in allowed else '初始化未成功：检查目录授权、Command Line Tools 和系统调试许可。未修改系统安全设置。')
        result=2
    raise SystemExit(result)
