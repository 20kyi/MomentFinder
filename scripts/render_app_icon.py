"""앱 아이콘(뷰파인더 + 반짝임)을 그려 Assets.xcassets/AppIcon.appiconset 에 저장합니다.

    python3 scripts/render_app_icon.py

iOS 는 시스템이 모서리를 잘라내므로 꽉 찬 정사각형을, macOS 는 직접 모양을 그려야 하므로
HIG 그리드(1024 캔버스 안 824 크기 둥근 사각형 + 그림자)를 따릅니다.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "MomentFinder/Resources/Assets.xcassets/AppIcon.appiconset"

NAVY_TOP = (22, 40, 86)
NAVY_BOTTOM = (11, 24, 58)
WHITE = (255, 255, 255)
AMBER_CORE = (255, 214, 92)
AMBER_GLOW = (255, 176, 32)

SS = 4  # 안티앨리어싱용 슈퍼샘플링 배율
MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def vertical_gradient(size, top, bottom):
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((size, size))


def draw_bracket(draw, corner, dx, dy, arm, radius, width, fill):
    """corner 에서 (dx, dy) 방향으로 뻗는 둥근 L 자 모서리 하나."""
    cx, cy = corner
    half = width / 2
    # 둥근 모서리 호
    box_x = (cx, cx + 2 * radius * dx)
    box_y = (cy, cy + 2 * radius * dy)
    bbox = [min(box_x) - half, min(box_y) - half, max(box_x) + half, max(box_y) + half]
    start = {(1, 1): 180, (-1, 1): 270, (-1, -1): 0, (1, -1): 90}[(dx, dy)]
    draw.arc(bbox, start, start + 90, fill=fill, width=round(width))
    # 가로·세로 팔
    hx0, hx1 = sorted((cx + radius * dx, cx + arm * dx))
    draw.rectangle([hx0, cy - half, hx1, cy + half], fill=fill)
    vy0, vy1 = sorted((cy + radius * dy, cy + arm * dy))
    draw.rectangle([cx - half, vy0, cx + half, vy1], fill=fill)
    # 끝을 둥글게
    for ex, ey in ((cx + arm * dx, cy), (cx, cy + arm * dy)):
        draw.ellipse([ex - half, ey - half, ex + half, ey + half], fill=fill)


def sparkle_polygon(cx, cy, r, pinch=0.13, steps=48):
    """끝이 뾰족하고 변이 오목한 네 갈래 별."""
    tips = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    points = []
    for i in range(4):
        (x0, y0), (x2, y2) = tips[i], tips[(i + 1) % 4]
        sx = 1 if (x0 + x2) / 2 > cx else -1
        sy = 1 if (y0 + y2) / 2 > cy else -1
        x1, y1 = cx + sx * pinch * r, cy + sy * pinch * r
        for s in range(steps):
            t = s / steps
            u = 1 - t
            points.append((u * u * x0 + 2 * u * t * x1 + t * t * x2,
                           u * u * y0 + 2 * u * t * y1 + t * t * y2))
    return points


def render_artwork(size):
    """size×size 꽉 찬 정사각형 아트워크(RGB)."""
    big = size * SS
    img = vertical_gradient(big, NAVY_TOP, NAVY_BOTTOM).convert("RGBA")

    # 뷰파인더 모서리
    frame = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(frame)
    inset, arm, radius, width = 0.235 * big, 0.135 * big, 0.06 * big, 0.044 * big
    lo, hi = inset, big - inset
    for corner, dx, dy in (((lo, lo), 1, 1), ((hi, lo), -1, 1), ((hi, hi), -1, -1), ((lo, hi), 1, -1)):
        draw_bracket(draw, corner, dx, dy, arm, radius, width, WHITE + (255,))
    img.alpha_composite(frame)

    # 반짝임(번짐 + 본체)
    star = sparkle_polygon(big / 2, big / 2, 0.165 * big)
    glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(glow).polygon(star, fill=AMBER_GLOW + (170,))
    glow = glow.filter(ImageFilter.GaussianBlur(0.035 * big))
    img.alpha_composite(glow)
    body = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(body).polygon(star, fill=AMBER_CORE + (255,))
    img.alpha_composite(body)

    return img.resize((size, size), Image.LANCZOS).convert("RGB")


def render_mac(artwork):
    """macOS HIG 그리드: 1024 캔버스, 824 둥근 사각형(반경 185), 아래로 떨어지는 그림자."""
    canvas, body, radius = 1024 * SS, 824 * SS, 185 * SS
    offset = (canvas - body) // 2

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius, fill=255)

    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (canvas, canvas), 0)
    shadow_mask.paste(mask, (offset, offset + 12 * SS))
    shadow.putalpha(shadow_mask.point(lambda a: a * 0.45).filter(ImageFilter.GaussianBlur(14 * SS)))

    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    img.alpha_composite(shadow)
    img.paste(artwork.resize((body, body), Image.LANCZOS), (offset, offset), mask)
    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    artwork = render_artwork(1024)
    artwork.save(ICONSET / "AppIcon-iOS.png")

    mac = render_mac(artwork)
    for px in MAC_SIZES:
        mac.resize((px, px), Image.LANCZOS).save(ICONSET / f"AppIcon-mac-{px}.png")

    images = [{"filename": "AppIcon-iOS.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            images.append({
                "filename": f"AppIcon-mac-{pt * scale}.png",
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{pt}x{pt}",
            })
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    (ICONSET.parent / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
