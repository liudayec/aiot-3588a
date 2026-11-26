import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
t = open(r'D:\deepseekgongzuoqu\diag\diff_v.txt', encoding='utf-8', errors='replace').read()
lines = t.split('\n')
# 找 vol1-heal 附近的差异块
inblock = False
buf = []
for i, l in enumerate(lines):
    if 'vol1-heal' in l or 'trim_file_monitor' in l:
        inblock = True
    if inblock:
        buf.append(l)
        if len(buf) > 90:
            break
print('\n'.join(buf[:90]))
