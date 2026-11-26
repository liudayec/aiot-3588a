import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
# 数节点
magic, total, off_s, off_str = struct.unpack('>IIII', d[0:16])
n = 0
p = off_s
while p < off_str:
    t = struct.unpack('>I', d[p:p+4])[0]; p += 4
    if t == 1:
        e = d.index(b'\x00', p); p = (e+1+3)&~3; n += 1
    elif t == 2:
        pass
    elif t == 3:
        ln, no = struct.unpack('>II', d[p:p+8]); p = (p+8+ln+3)&~3
    elif t == 9: break
print('  DTB: %d 字节, %d 个节点' % (len(d), n))
print()
for k, v in [
    ('bcmdhd_wlan 兼容', b'android,bcmdhd_wlan'),
    ('gpio_wl_reg_on', b'gpio_wl_reg_on'),
    ('WIFI,poweren-gpios', b'WIFI,poweren-gpios'),
    ('WIFI,host_wake-gpios', b'WIFI,host_wake-gpios'),
    ('gpio-leds', b'gpio-leds'),
    ('led pwr', b'pwr'),
    ('led data', b'data'),
    ('led 4g', b'4g'),
    ('4g-reset-hog', b'4g-reset-hog'),
    ('phone-en-hog', b'phone-en-hog'),
    ('4g-power-hog', b'4g-power-hog'),
    ('usb0-power-hog', b'usb0-power-hog'),
    ('GPIO RECOVERY', b'GPIO RECOVERY'),
    ('HDMI enable-gpios', b'enable-gpios'),
    ('clocks 8个(含mac_clk_rx)', b'mac_clk_rx'),
    ('local-mac-address', b'local-mac-address'),
    ('motorcomm', b'motorcomm'),
]:
    print('  %s %s' % ('OK  ' if v in d else 'FAIL', k))
