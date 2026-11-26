import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
now = open(r'D:\work\aiot-3588a\kdevbuild\fix_rootfs_fstab.sh', encoding='utf-8', errors='replace').read()
import subprocess
old = subprocess.run(['git','show','7d5eb97:kdevbuild/fix_rootfs_fstab.sh'],
                     cwd=r'D:\work\aiot-3588a', capture_output=True, text=True,
                     encoding='utf-8', errors='replace').stdout

def svcs(t):
    return set(re.findall(r'cat > "\$MNT/etc/systemd/system/([^"]+)"', t))
def scripts(t):
    return set(re.findall(r'cat > "\$MNT/usr/local/sbin/([^"]+)"', t))

so, sn = svcs(old), svcs(now)
po, pn = scripts(old), scripts(now)
print('=== 新增的服务 ===')
for s in sorted(sn - so): print('  + %s' % s)
print('=== 新增的脚本 ===')
for s in sorted(pn - po): print('  + %s' % s)
print('=== 1104 有但现在没有的 ===')
for s in sorted(so - sn): print('  - %s' % s)
for s in sorted(po - pn): print('  - %s' % s)
