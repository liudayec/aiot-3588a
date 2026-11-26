import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
for s in [b'ap6256', b'ap6398s', b'ap6275p', b'ap6xxx']:
    print('  %-10s %s' % (s.decode(), '有' if s in d else '无'))
