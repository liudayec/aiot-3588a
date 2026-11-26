import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
s = open(r'D:\work\aiot-3588a\kdevbuild\fix_rootfs_fstab.sh', encoding='utf-8', errors='replace').read()
m = re.search(r"trim-nca9555-all\.service\" <<'NCAEOF'\n([\s\S]*?)\nNCAEOF", s)
if m:
    print(m.group(1))
else:
    print('没找到')
