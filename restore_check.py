import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
print('  DTB: %d 字节' % len(d))
for k, v in [('clocks 8 个', b'mac_clk_rx\0mac_clk_tx\0clk_mac_speed'),
             ('local-mac-address', b'local-mac-address'),
             ('motorcomm', b'motorcomm'),
             ('bcmdhd_wlan', b'android,bcmdhd_wlan'),
             ('gpio_wl_reg_on', b'gpio_wl_reg_on'),
             ('WIFI,poweren', b'WIFI,poweren-gpios'),
             ('WIFI,host_wake', b'WIFI,host_wake-gpios'),
             ('4g-reset-hog', b'4g-reset-hog'),
             ('phone-en-hog', b'phone-en-hog'),
             ('GPIO RECOVERY', b'GPIO RECOVERY'),
             ('enable-gpios', b'enable-gpios')]:
    print('  %s %-22s' % ('有  ' if v in d else '缺失', k))
