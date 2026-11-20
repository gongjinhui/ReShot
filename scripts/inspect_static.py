#!/usr/bin/env python3
"""Supplemental offline Mach-O evidence; not REA output or a decompiler."""
import hashlib
import json
import struct
from pathlib import Path

target = Path('/Applications/iShot.app/Contents/MacOS/iShot')
raw = target.read_bytes()
n = struct.unpack_from('>I', raw, 4)[0]
offset = next(struct.unpack_from('>IIIII', raw, 8 + 20*i)[2]
              for i in range(n)
              if struct.unpack_from('>I', raw, 8 + 20*i)[0] == 0x100000c)
data = raw[offset:]
commands = struct.unpack_from('<I', data, 16)[0]
segments = []
sections = []
pos = 32
for _ in range(commands):
    cmd, size = struct.unpack_from('<II', data, pos)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, pos+24)
        segments.append((vmaddr, fileoff, filesize))
        count = struct.unpack_from('<I', data, pos+64)[0]
        for i in range(count):
            s = pos+72+80*i
            name = data[s:s+16].split(b'\0')[0].decode()
            addr, length, file = struct.unpack_from('<QQI', data, s+32)
            sections.append((name, addr, length, file))
    pos += size

def at(addr):
    for vm, file, size in segments:
        if vm <= addr < vm+size:
            return file+addr-vm
    raise ValueError(hex(addr))

def cstring(addr):
    start = at(addr)
    return data[start:data.index(b'\0', start)].decode('utf-8', errors='replace')

def pointer(addr):
    return struct.unpack_from('<Q', data, at(addr))[0]

stubs = {}
for name, addr, length, file in sections:
    if name != '__objc_stubs':
        continue
    for delta in range(0, length, 32):
        a, b = struct.unpack_from('<II', data, file+delta)
        if a & 0x9f000000 != 0x90000000 or b & 0xffc00000 != 0xf9400000:
            continue
        imm = ((a >> 5 & 0x7ffff) << 2) | (a >> 29 & 3)
        if imm & 0x100000:
            imm -= 0x200000
        selref = ((addr+delta) & ~0xfff) + (imm << 12) + ((b >> 10 & 0xfff)*8)
        stubs[hex(addr+delta)] = cstring(pointer(selref))

languages = []
for addr in range(0x1001ad8a0, 0x1001ad9a0, 32):
    try:
        languages.append({'cfstring_address': hex(addr), 'text': cstring(pointer(addr+16))})
    except ValueError:
        pass

out = {'source': str(target), 'sha256': hashlib.sha256(raw).hexdigest(),
       'architecture': 'arm64', 'slice_offset': offset,
       'kind': 'supplemental direct byte parsing, not REA Evidence',
       'objc_stubs': stubs, 'ocr_language_constants': languages,
       'limitations': ['Static bytes only; no runtime observation.',
                       'Only standard ARM64 adrp/ldr Objective-C selector stubs are decoded.']}
Path('evidence/static-selectors.json').write_text(json.dumps(out, ensure_ascii=False, indent=2))
print(json.dumps({'decoded_stubs': len(stubs), 'ocr_language_constants': languages}, ensure_ascii=False, indent=2))
