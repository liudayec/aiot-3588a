import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 解析 DTB 的 FDT 结构，找到 recovery 节点的 gpios 属性
data = open(r'D:\work\aiot-3588a\kdevbuild\dtb\rk3588-aiot-3588a.dtb','rb').read()
print('DTB 大小: %d' % len(data))
print('magic: 0x%08x (应为 0xd00dfeed)' % struct.unpack('>I', data[0:4])[0])

magic, totalsize, off_struct, off_strings = struct.unpack('>IIII', data[0:16])
print('size=%d struct=%d strings=%d' % (totalsize, off_struct, off_strings))

# 解析结构块
p = off_struct
depth = 0
cur_node = []
nodes = {}

def read_str(off):
    end = data.index(b'\x00', off_strings + off)
    return data[off_strings+off:end].decode('utf-8','replace')

while p < len(data):
    tok = struct.unpack('>I', data[p:p+4])[0]
    p += 4
    if tok == 1:  # FDT_BEGIN_NODE
        end = data.index(b'\x00', p)
        name = data[p:end].decode('utf-8','replace')
        p = end + 1
        p = (p + 3) & ~3
        depth += 1
        cur_node.append(name)
    elif tok == 2:  # FDT_END_NODE
        if cur_node: cur_node.pop()
        depth -= 1
    elif tok == 3:  # FDT_PROP
        ln, nameoff = struct.unpack('>II', data[p:p+8])
        p += 8
        val = data[p:p+ln]
        p += ln
        p = (p + 3) & ~3
        pname = read_str(nameoff)
        full = '/'.join(cur_node)
        if 'recovery' in full and pname == 'gpios':
            cells = struct.unpack('>%dI' % (ln//4), val)
            print('\n★ 找到 recovery 的 gpios:')
            print('  节点: %s' % full)
            print('  原始: %s' % (val.hex()))
            print('  cells: %s' % [hex(c) for c in cells])
            if len(cells) >= 2:
                bank = cells[0]
                pin = cells[1]
                flag = cells[2] if len(cells) > 2 else 0
                print('  phandle=0x%x  pin=%d (GPIO?_%d)  flag=0x%x' % (bank, pin, pin, flag))
                print()
                if pin == 6:
                    print('  ✅ 是 GPIO?_6 = gpio-38')
                elif pin == 9:
                    print('  ❌ 是 GPIO?_9 = gpio-41（旧值！）')
    elif tok == 4:  # FDT_NOP
        pass
    elif tok == 9:  # FDT_END
        break
