#!/usr/bin/env python3
"""アプリケーションアイコン res/kxnotifyutils.ico を生成する。

外部ライブラリを使わずに PNG を組み立て、PNG 形式のエントリを持つ ICO として書き出す。
Windows Vista 以降は PNG エントリの ICO を読めるため、この形式で足りる。
生成物はリポジトリに含めるので、通常のビルドでこのスクリプトを走らせる必要はない。
"""
import struct
import zlib

SIZES = [16, 24, 32, 48, 64, 128, 256]

BACKGROUND = (0x1F, 0x2A, 0x37, 0xFF)
ACCENT = (0x4C, 0x9A, 0xFF, 0xFF)
GLYPH = (0xFF, 0xFF, 0xFF, 0xFF)

SS = 4  # スーパーサンプリングの倍率


def blend(dst, src):
    a = src[3] / 255.0
    return tuple(int(src[i] * a + dst[i] * (1 - a)) for i in range(3)) + (255,)


def rounded_rect(x, y, w, h, radius, px, py):
    if px < x or py < y or px >= x + w or py >= y + h:
        return False
    cx = min(max(px, x + radius), x + w - radius)
    cy = min(max(py, y + radius), y + h - radius)
    return (px - cx) ** 2 + (py - cy) ** 2 <= radius ** 2 or (
        x + radius <= px < x + w - radius or y + radius <= py < y + h - radius
    )


def bell(px, py, size):
    """ベルの形。本体は下すぼまりの釣鐘、下に受け皿と振り子を置く。"""
    x = (px - size / 2) / size
    y = (py - size / 2) / size

    # 釣鐘の本体
    if -0.24 <= y <= 0.12:
        t = (y + 0.24) / 0.36
        half = 0.10 + 0.20 * (t ** 1.5)
        if abs(x) <= half:
            return True
    # 上のつまみ
    if (x ** 2 + (y + 0.28) ** 2) <= 0.045 ** 2:
        return True
    # 受け皿
    if 0.12 <= y <= 0.17 and abs(x) <= 0.34:
        return True
    # 振り子
    if (x ** 2 + (y - 0.24) ** 2) <= 0.07 ** 2:
        return True
    return False


def render(size):
    pixels = [[BACKGROUND for _ in range(size)] for _ in range(size)]
    radius = size * 0.22

    for py in range(size):
        for px in range(size):
            inside = 0
            glyph = 0
            for sy in range(SS):
                for sx in range(SS):
                    fx = px + (sx + 0.5) / SS
                    fy = py + (sy + 0.5) / SS
                    if rounded_rect(0, 0, size, size, radius, fx, fy):
                        inside += 1
                        if bell(fx, fy, size):
                            glyph += 1
            total = SS * SS
            if inside == 0:
                pixels[py][px] = (0, 0, 0, 0)
                continue

            base = blend((0, 0, 0, 0), BACKGROUND[:3] + (int(255 * inside / total),))
            accent_strength = 1.0 - py / size
            base = blend(base, ACCENT[:3] + (int(70 * accent_strength),))
            if glyph:
                base = blend(base, GLYPH[:3] + (int(255 * glyph / total),))
            pixels[py][px] = base[:3] + (int(255 * inside / total),)
    return pixels


def to_png(pixels):
    size = len(pixels)
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def main():
    images = [(size, to_png(render(size))) for size in SIZES]

    out = bytearray(struct.pack("<HHH", 0, 1, len(images)))
    offset = 6 + 16 * len(images)
    for size, data in images:
        out += struct.pack(
            "<BBBBHHII", size if size < 256 else 0, size if size < 256 else 0, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
    for _, data in images:
        out += data

    with open("res/kxnotifyutils.ico", "wb") as handle:
        handle.write(bytes(out))
    print("wrote res/kxnotifyutils.ico (%d bytes)" % len(out))


if __name__ == "__main__":
    main()
