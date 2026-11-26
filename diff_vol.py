import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
lines = open(r'D:\deepseekgongzuoqu\diag\d.txt', encoding='utf-8', errors='replace').read().split('\n')
# 找所有 + 行里含 vol1 / file_monitor / storage 的
shown = 0
for i, l in enumerate(lines):
    if l.startswith('+') and not l.startswith('+++'):
        if any(k in l for k in ['vol1', 'file_monitor', 'storage-release', 'trim_main', 'After=', 'Before=']):
            print('  %s' % l[:130])
            shown += 1
            if shown > 40: break
