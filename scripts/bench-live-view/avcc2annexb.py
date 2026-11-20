# baguette AVCC stdout ([u32 len][u8 tag][payload]) -> Annex-B H.264 on stdout.
# SPS/PPS repeated before each IDR; an AUD after each frame so ffmpeg's parser flushes it at once.
import sys, struct
inp, out = sys.stdin.buffer, sys.stdout.buffer
SC = b'\x00\x00\x00\x01'; AUD = SC + b'\x09\xf0'
params = b''
def read(n):
    b = b''
    while len(b) < n:
        c = inp.read(n - len(b))
        if not c: sys.exit(0)
        b += c
    return b
def avcc_to_annexb(p):
    o, i = [], 0
    while i + 4 <= len(p):
        n = struct.unpack('>I', p[i:i+4])[0]; o.append(SC + p[i+4:i+4+n]); i += 4 + n
    return b''.join(o)
def parse_avcc_record(r):
    i = 5; ps = []
    nsps = r[i] & 0x1f; i += 1
    for _ in range(nsps):
        n = struct.unpack('>H', r[i:i+2])[0]; ps.append(SC + r[i+2:i+2+n]); i += 2 + n
    npps = r[i]; i += 1
    for _ in range(npps):
        n = struct.unpack('>H', r[i:i+2])[0]; ps.append(SC + r[i+2:i+2+n]); i += 2 + n
    return b''.join(ps)
while True:
    n = struct.unpack('>I', read(4))[0]
    chunk = read(n); tag, p = chunk[0], chunk[1:]
    if tag == 1: params = parse_avcc_record(p)
    elif tag in (2, 3) and params:
        out.write((params if tag == 2 else b'') + avcc_to_annexb(p) + AUD); out.flush()
