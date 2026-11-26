import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
s = open(r'D:\work\aiot-3588a\kdevbuild\fix_rootfs_fstab.sh', encoding='utf-8', errors='replace').read()
for svc in ['G4IPEOF', 'G4EOF', 'APNEOF']:
    m = re.search(r"<<'%s'\n([\s\S]*?)\n%s" % (svc, svc), s)
    if m:
        print('\n--- %s ---' % svc)
        print(m.group(1))
