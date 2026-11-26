import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
print('  DTB: %d 字节' % len(d))
for k, v in [
    ('bcmdhd_wlan', b'android,bcmdhd_wlan'),
    ('gpio_wl_reg_on', b'gpio_wl_reg_on'),
    ('WIFI,poweren-gpios', b'WIFI,poweren-gpios'),
    ('WIFI,host_wake-gpios', b'WIFI,host_wake-gpios'),
    ('led pwr', b'pwr'),
    ('led data', b'data'),
    ('led 4g', b'4g'),
    ('4g-reset-hog', b'4g-reset-hog'),
    ('phone-en-hog', b'phone-en-hog'),
    ('4g-power-hog', b'4g-power-hog'),
    ('usb0-power-hog', b'usb0-power-hog'),
    ('GPIO RECOVERY', b'GPIO RECOVERY'),
    ('enable-gpios', b'enable-gpios'),
]:
    print('  %s %-24s' % ('有  ' if v in d else '缺失', k))
