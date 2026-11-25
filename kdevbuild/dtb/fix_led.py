import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
p = r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dts'
s = open(p, encoding='utf-8', errors='replace').read()
m = re.search(r'breathe-led-hog \{.*?\};', s, re.S)
if m:
    blk = m.group(0)
    print('原:'); print(blk)
    new = blk.replace('output-high','output-low')
    s = s.replace(blk, new)
    open(p,'w',encoding='utf-8',newline='\n').write(s)
    print('\n新:'); print(new)
else:
    print('没找到 breathe-led-hog')
