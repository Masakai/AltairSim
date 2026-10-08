#!/usr/bin/env python3
"""アプリのアイコン(Altair 8800 の前面パネル風)を描いて AppIcon.icns を作る。

使い方: python3 Tools/make_icon.py <出力フォルダ>
  出力: <出力フォルダ>/AppIcon.icns(iconutil が必要)
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024

def font(size):
    for p in ("/System/Library/Fonts/Avenir Next.ttc", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(p):
            try: return ImageFont.truetype(p, size, index=0)
            except Exception: pass
    return ImageFont.load_default()

def draw():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # 角丸の本体(macOS のアイコンと同じ余白: 外周 100px)
    m, r = 100, 185
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / S
        gd.line([(0, y), (S, y)], fill=(int(27 - 12 * t), int(52 - 24 * t), int(98 - 44 * t), 255))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], r, fill=255)
    body.paste(grad, (0, 0), mask)
    # 影
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + 18, S - m, S - m + 18], r, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    img.alpha_composite(shadow)
    img.alpha_composite(body)

    d = ImageDraw.Draw(img)
    # 黒いパネル
    px0, py0, px1, py1 = 170, 190, S - 170, 640
    d.rounded_rectangle([px0, py0, px1, py1], 40, fill=(12, 14, 20, 255), outline=(214, 190, 120, 255), width=6)

    # LED 2 行(点灯パターン)
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    lit_rows = [
        [1, 1, 0, 0, 1, 0, 1, 1],
        [0, 1, 0, 1, 1, 0, 0, 1],
    ]
    xs = [px0 + 80 + i * ((px1 - px0 - 160) / 7) for i in range(8)]
    for row, y in zip(lit_rows, (270, 350)):
        for x, on in zip(xs, row):
            if on:
                gdraw.ellipse([x - 34, y - 34, x + 34, y + 34], fill=(255, 40, 30, 255))
    glow_blur = glow.filter(ImageFilter.GaussianBlur(26))
    img.alpha_composite(glow_blur)
    d = ImageDraw.Draw(img)
    for row, y in zip(lit_rows, (270, 350)):
        for x, on in zip(xs, row):
            if on:
                d.ellipse([x - 22, y - 22, x + 22, y + 22], fill=(255, 92, 70, 255))
                d.ellipse([x - 10, y - 14, x + 4, y - 2], fill=(255, 200, 180, 255))
            else:
                d.ellipse([x - 22, y - 22, x + 22, y + 22], fill=(70, 20, 22, 255))

    # トグルスイッチ(上下がまちまち)
    ups = [1, 0, 1, 1, 0, 0, 1, 0]
    for x, up in zip(xs, ups):
        d.rounded_rectangle([x - 11, 440, x + 11, 560], 11, fill=(36, 40, 52, 255))
        ty = 458 if up else 540
        d.ellipse([x - 24, ty - 24, x + 24, ty + 24], fill=(214, 218, 226, 255), outline=(120, 126, 140, 255), width=4)

    # 文字
    d.text((S // 2, 745), "ALTAIR", font=font(150), fill=(232, 236, 245, 255), anchor="mm")
    d.text((S // 2, 855), "8800 · 680b", font=font(70), fill=(168, 186, 222, 255), anchor="mm")
    return img

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    base = draw()
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        base.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        base.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    base.save(os.path.join(out, "AppIcon-1024.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)
    print("wrote", os.path.join(out, "AppIcon.icns"))

if __name__ == "__main__":
    main()
