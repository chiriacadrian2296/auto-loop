"""Rasterizes the AutoLoop mark into windows/runner/resources/app_icon.ico."""
import math
from PIL import Image, ImageDraw

def arc(r, a0, a1, n=96):
    return [(r * math.cos(a0 + (a1 - a0) * i / n), r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]

def piece(sign):
    # Ring segment on one side of the 45-degree band |x - y| < 25.
    o0, o1 = math.atan2(-100, -75), math.atan2(75, 100)
    i0, i1 = math.atan2(-73.457, -48.457), math.atan2(48.457, 73.457)
    if sign < 0:
        o0, o1, i0, i1 = o0 + math.pi, o1 + math.pi, i0 + math.pi, i1 + math.pi
    return arc(125, o0, o1) + arc(88, i1, i0)

BAR = [(-72, -47), (-22, -47), (72, 47), (22, 47)]

def render(size, ss=8):
    s = size * ss
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=56 / 256 * s, fill=(0x3D, 0x7B, 0xFD, 255))
    k = s / 256 * 0.68
    for poly in (piece(1), piece(-1), BAR):
        d.polygon([(s / 2 + x * k, s / 2 + y * k) for x, y in poly], fill=(255, 255, 255, 255))
    return img.resize((size, size), Image.LANCZOS)

sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
render(256).save('windows/runner/resources/app_icon.ico', sizes=[(n, n) for n in sizes])
render(512).save('assets/logo/app-icon-512.png')
print('ok')
