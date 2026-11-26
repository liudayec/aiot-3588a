import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
lines = open(r'D:\deepseekgongzuoqu\diag\d.txt', encoding='utf-8', errors='replace').read().split('\n')
added = [l[1:].strip() for l in lines if l.startswith('+') and not l.startswith('+++')]
# 找新增的服务文件
svc = [a for a in added if a.startswith('cat >') or '.service"' in a or 'trim-' in a]
for s in svc[:60]:
    print('  %s' % s[:130])
