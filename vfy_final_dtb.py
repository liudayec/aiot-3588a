import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
print('  DTB: %d 字节' % len(d))
# 检查属性（不是字符串）
magic, total, off_s, off_str = struct.unpack('>IIII', d[0:16])
SE, SS = off_str, off_str
def rs(o):
    e = d.index(b'\x00', SS+o)
    return d[SS+o:e].decode('utf-8','replace')
p = off_s; depth=0; cur=[]; props={}
found = {}
while p < SE:
    t = struct.unpack('>I', d[p:p+4])[0]; p += 4
    if t==1:
        e=d.index(b'\x00',p); n=d[p:e].decode('utf-8','replace'); p=(e+1+3)&~3
        depth+=1; cur.append(n); props={}
    elif t==2:
        if cur:
            path='/'.join(cur)
            for k,v in props.items():
                if k in ('gpio_wl_reg_on','WIFI,poweren-gpios','WIFI,host_wake-gpios','snps,reset-gpio'):
                    found[(path,k)] = v
            cur.pop()
        depth-=1; props={}
    elif t==3:
        ln,no=struct.unpack('>II',d[p:p+8]); v=d[p+8:p+8+ln]; p=(p+8+ln+3)&~3
        props[rs(no)]=v
    elif t==9: break

for (path,k), v in sorted(found.items()):
    cells = struct.unpack('>%dI'%(len(v)//4), v) if len(v)%4==0 and len(v)>=8 else ()
    print('  %-28s %-22s %s' % (path[:28], k, [hex(c) for c in cells] if cells else v.hex()))
print()
print('  gpio_wl_reg_on 属性: %s' % ('还在 ✗' if any(k=='gpio_wl_reg_on' for _,k in found) else '已删除 ✓'))
