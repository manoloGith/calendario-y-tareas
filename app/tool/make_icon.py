"""Genera el icono de la app (calendario + tarea completada) en PNG e ICO.

Uso: python3 tool/make_icon.py   (desde app/; requiere Pillow)
Salida: assets/icon/app_icon.png (1024), app_icon_<n>.png, app_icon.ico
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supermuestreo
N = 1024 * S
OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"


def vgrad(w, h, top, bottom):
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return g.resize((w, h))


def rrect_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=r, fill=255)
    return m


def build():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    m = 84 * S
    body = (m, m + 10 * S, N - m, N - m)
    radius = 190 * S

    # Sombra suave
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((body[0], body[1] + 18 * S, body[2], body[3] + 18 * S), radius=radius, fill=(0, 0, 0, 90))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(26 * S)))

    # Hoja blanca
    mask = rrect_mask((N, N), body, radius)
    sheet = vgrad(N, N, (255, 255, 255, 255), (236, 238, 244, 255))
    img.paste(sheet, (0, 0), mask)

    # Cabecera roja
    head_h = 300 * S
    head = vgrad(N, N, (255, 94, 82, 255), (226, 46, 38, 255))
    hm = Image.new("L", (N, N), 0)
    hm.paste(mask.crop((0, 0, N, body[1] + head_h)), (0, 0))
    img.paste(head, (0, 0), hm)
    d = ImageDraw.Draw(img)
    # Anillas
    for cx in (N * 0.34, N * 0.66):
        d.rounded_rectangle((cx - 26 * S, body[1] - 34 * S, cx + 26 * S, body[1] + 92 * S), radius=26 * S, fill=(255, 255, 255, 255))
        d.rounded_rectangle((cx - 26 * S, body[1] + 40 * S, cx + 26 * S, body[1] + 92 * S), radius=26 * S, fill=(196, 36, 30, 255))
    # Línea de texto en la cabecera (sugiere el mes)
    d.rounded_rectangle((N * 0.30, body[1] + 170 * S, N * 0.70, body[1] + 222 * S), radius=26 * S, fill=(255, 255, 255, 235))

    # Cuadrícula de días
    top = body[1] + head_h + 62 * S
    cols, rows = 4, 3
    x0, x1 = body[0] + 92 * S, body[2] - 92 * S
    y1 = body[3] - 92 * S
    cw = (x1 - x0) / cols
    ch = (y1 - top) / rows
    for r in range(rows):
        for c in range(cols):
            bx = x0 + c * cw + 14 * S
            by = top + r * ch + 14 * S
            color = (255, 59, 48, 255) if (r, c) == (0, 1) else (218, 222, 231, 255)
            d.rounded_rectangle((bx, by, bx + cw - 28 * S, by + ch - 28 * S), radius=26 * S, fill=color)

    # Insignia azul con marca de verificación (tareas)
    cx, cy, rad = N * 0.735, N * 0.735, 205 * S
    ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((cx - rad - 8 * S, cy - rad + 14 * S, cx + rad + 8 * S, cy + rad + 30 * S), fill=(0, 0, 0, 80))
    img.alpha_composite(ring.filter(ImageFilter.GaussianBlur(18 * S)))
    d = ImageDraw.Draw(img)
    d.ellipse((cx - rad - 26 * S, cy - rad - 26 * S, cx + rad + 26 * S, cy + rad + 26 * S), fill=(255, 255, 255, 255))
    badge = vgrad(N, N, (64, 156, 255, 255), (0, 96, 223, 255))
    bm = Image.new("L", (N, N), 0)
    ImageDraw.Draw(bm).ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=255)
    img.paste(badge, (0, 0), bm)
    d = ImageDraw.Draw(img)
    pts = [(cx - rad * 0.46, cy + rad * 0.02), (cx - rad * 0.12, cy + rad * 0.36), (cx + rad * 0.50, cy - rad * 0.32)]
    w = int(58 * S)
    d.line(pts, fill=(255, 255, 255, 255), width=w, joint="curve")
    for p in (pts[0], pts[-1]):
        d.ellipse((p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2), fill=(255, 255, 255, 255))

    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    big = build()
    big.save(OUT / "app_icon.png")
    for n in (16, 32, 48, 64, 128, 256, 512):
        big.resize((n, n), Image.LANCZOS).save(OUT / f"app_icon_{n}.png")
    big.save(OUT / "app_icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    # Android (mipmap)
    for d, n in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        (OUT / "android" / f"mipmap-{d}").mkdir(parents=True, exist_ok=True)
        big.resize((n, n), Image.LANCZOS).save(OUT / "android" / f"mipmap-{d}" / "ic_launcher.png")
    print("Icono generado en", OUT)


if __name__ == "__main__":
    main()
