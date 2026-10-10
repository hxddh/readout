"""Generates the Readout app icon: a sheet of text lines with one accent change rail."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas (4x of 1024)
k = S / 1024

def squircle_mask(size, rect, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(rect, radius=radius, fill=255)
    return m

def make():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    x0, y0, x1, y1 = [int(v * k) for v in (100, 100, 924, 924)]
    radius = int(186 * k)

    # Drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + int(14 * k), x1, y1 + int(14 * k)), radius=radius, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(22 * k)))
    img.alpha_composite(shadow)

    # Sheet with a faint vertical gradient
    sheet = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    grad = Image.new("RGBA", (1, y1 - y0))
    for y in range(y1 - y0):
        t = y / (y1 - y0)
        c = (int(255 - 9 * t), int(255 - 8 * t), int(255 - 6 * t), 255)
        grad.putpixel((0, y), c)
    grad = grad.resize((x1 - x0, y1 - y0))
    sheet.paste(grad, (x0, y0))
    mask = squircle_mask(S, (x0, y0, x1, y1), radius)
    img.paste(sheet, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # Hairline edge
    d.rounded_rectangle((x0, y0, x1, y1), radius=radius, outline=(0, 0, 0, 28), width=int(2 * k))

    ink = (58, 58, 64, 255)
    soft = (196, 197, 204, 255)
    accent = (10, 132, 255, 255)
    left = int(292 * k)
    bar_h = int(46 * k)
    r = bar_h // 2

    def line(y, length, color):
        d.rounded_rectangle((left, int(y * k), left + int(length * k), int(y * k) + bar_h), radius=r, fill=color)

    # Heading
    d.rounded_rectangle((left, int(250 * k), left + int(330 * k), int(250 * k) + int(64 * k)), radius=int(32 * k), fill=ink)
    # Body lines
    line(372, 500, soft)
    line(446, 440, soft)
    # Changed block (with the rail)
    line(548, 500, (150, 170, 196, 255))
    line(622, 380, (150, 170, 196, 255))
    d.rounded_rectangle((int(226 * k), int(540 * k), int(226 * k) + int(26 * k), int(676 * k)), radius=int(13 * k), fill=accent)
    # Trailing line
    line(724, 300, soft)

    return img.resize((1024, 1024), Image.LANCZOS)

def main(out):
    base = make()
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            base.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    base.save(os.path.join(out, "..", "..", "..", "tools", "icon-1024.png"))

if __name__ == "__main__":
    main(sys.argv[1])
