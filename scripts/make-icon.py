#!/usr/bin/env python3
"""Generate the local app icon. No network, no external assets."""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "AppIcon.icns"
WORK = ROOT / "work" / "app-icon.iconset"
SIZE = 1024


def rounded_mask(size, radius):
    width, height = size if isinstance(size, tuple) else (size, size)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=255)
    return mask


def make_master():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    # Soft outer shadow keeps the icon readable on light and dark docks.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_mask = rounded_mask(SIZE, 228)
    shadow_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 80))
    shadow.putalpha(shadow_mask)
    shadow = Image.composite(shadow_layer, shadow, shadow_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow, (0, 14))

    box = (54, 42, SIZE - 54, SIZE - 86)
    w, h = box[2] - box[0], box[3] - box[1]
    rounded = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pix = image.load()
    for y in range(h):
        t = y / max(1, h - 1)
        top = (10, 166, 86)
        bottom = (3, 96, 55)
        color = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(w):
            pix[x, y] = (*color, 255)
    # Top-left glass highlight.
    shine = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shine)
    sd.ellipse((-w * 0.25, -h * 0.55, w * 0.85, h * 0.34), fill=(255, 255, 255, 38))
    image.alpha_composite(shine)
    rounded.paste(image, (0, 0), rounded_mask((w, h), 214))
    canvas.alpha_composite(rounded, (box[0], box[1]))

    draw = ImageDraw.Draw(canvas)
    # Conversation bubble.
    bubble = (276, 344, 814, 760)
    draw.rounded_rectangle(bubble, radius=92, fill=(255, 255, 255, 242))
    draw.polygon([(344, 746), (298, 836), (430, 752)], fill=(255, 255, 255, 242))
    # Three message dots.
    for x in (398, 545, 692):
        draw.ellipse((x - 28, 524 - 28, x + 28, 524 + 28), fill=(7, 136, 66, 255))
    # Small companion sparkle.
    cx, cy = 802, 306
    draw.polygon([(cx, cy - 58), (cx + 16, cy - 16), (cx + 58, cy), (cx + 16, cy + 16),
                  (cx, cy + 58), (cx - 16, cy + 16), (cx - 58, cy), (cx - 16, cy - 16)],
                 fill=(255, 230, 138, 255))
    return canvas


def main():
    master = make_master()
    WORK.parent.mkdir(parents=True, exist_ok=True)
    if WORK.exists():
        import shutil
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True)
    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        master.resize((size, size), Image.Resampling.LANCZOS).save(WORK / name)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(WORK), "-o", str(OUT)], check=True)
    print(OUT)


if __name__ == "__main__":
    main()
