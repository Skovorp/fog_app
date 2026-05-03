"""Generate 3 App Store screenshots for `feral`.

Output: /Users/ksc/feral_analysis/yc_demo/v2/appstore/screen_{1,2,3}.png
Size:   1290 × 2796 (iPhone 6.7" Pro Max portrait — standard App Store size)

The app itself is landscape-only, so screens 2 & 3 show landscape content
fitting the portrait canvas width with text above.
"""
from pathlib import Path
import fitz  # PyMuPDF
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = Path("/Users/ksc/feral_analysis/yc_demo/v2/appstore")
OUT.mkdir(exist_ok=True)

W, H = 1290, 2796
BG = (0, 0, 0)
WHITE = (255, 255, 255)
SECONDARY = (170, 170, 175)
TERTIARY = (110, 110, 115)
ACCENT = (10, 132, 255)
GREEN = (48, 209, 88)

ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"
DEFAULT = "/System/Library/Fonts/Helvetica.ttc"

def font(size, weight=700):
    try:
        f = ImageFont.truetype(ROUNDED, size)
        try:
            f.set_variation_by_axes([weight])
        except Exception:
            pass
        return f
    except Exception:
        return ImageFont.truetype(DEFAULT, size)

def draw_text(d, xy, text, f, fill=WHITE, anchor="lt"):
    d.text(xy, text, font=f, fill=fill, anchor=anchor)

def text_w(d, text, f):
    return d.textbbox((0, 0), text, font=f)[2]

# ──────────────────────────────────────────────────────────────────────
# Screen 1: All-text marketing
# ──────────────────────────────────────────────────────────────────────
def make_screen_1():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)

    title_f = font(180, 800)
    sub_f = font(70, 500)
    pill_f = font(54, 600)

    # Headline
    line1 = "Score"
    line2 = "freezing of gait."
    title_y = 380
    draw_text(d, (W // 2, title_y), line1, title_f, WHITE, anchor="mt")
    draw_text(d, (W // 2, title_y + 200), line2, title_f, WHITE, anchor="mt")

    # Subhead — explicitly call out Parkinson's symptom + the test
    sub_y = title_y + 480
    draw_text(d, (W // 2, sub_y), "A Parkinson's symptom,", sub_f, SECONDARY, anchor="mt")
    draw_text(d, (W // 2, sub_y + 100), "from a turn-in-place test.", sub_f, SECONDARY, anchor="mt")

    # Vertical stack of pills (portrait fits them better than horizontal)
    pills = [
        ("On-device", GREEN),
        ("No wifi", ACCENT),
        ("Real-time on iPhone 16+", WHITE),
    ]
    pill_y = sub_y + 320
    pad_x, pad_y = 56, 26
    h = pill_f.size + 2 * pad_y
    gap = 30
    for text, color in pills:
        w = text_w(d, text, pill_f) + 2 * pad_x
        x = (W - w) // 2
        d.rounded_rectangle((x, pill_y, x + w, pill_y + h), radius=h // 2, outline=color, width=4)
        draw_text(d, (W // 2, pill_y + h // 2), text, pill_f, color, anchor="mm")
        pill_y += h + gap

    # Footer note
    note = "feral · made for clinicians and researchers"
    note_f = font(36, 400)
    draw_text(d, (W // 2, H - 120), note, note_f, TERTIARY, anchor="mb")

    out = OUT / "screen_1.png"
    im.save(out)
    print(f"wrote {out}")

# ──────────────────────────────────────────────────────────────────────
# Screen 2: Live recording showcase (landscape phone screenshot)
# ──────────────────────────────────────────────────────────────────────
def make_screen_2():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)

    src = Image.open("/Users/ksc/.claude/image-cache/c1f80ab2-ab0a-4227-a81b-405c47caad8d/5.png").convert("RGB")
    # Source file is portrait but the *content* is the landscape app rotated
    # 90° clockwise. Rotate +90° (counterclockwise in PIL) to put the bar at
    # the bottom and the Stop button at the top-right where they actually are.
    src = src.rotate(90, expand=True)
    sw, sh = src.size  # 848 × 384 landscape

    # Trim a thin strip on each side to focus on action
    cl = int(sw * 0.04)
    cr = int(sw * 0.04)
    src = src.crop((cl, 0, sw - cr, sh))
    sw, sh = src.size

    # Headline at top
    title_f = font(150, 800)
    sub_f = font(64, 500)
    head_y = 220
    draw_text(d, (W // 2, head_y), "See freezing", title_f, WHITE, anchor="mt")
    draw_text(d, (W // 2, head_y + 170), "as it happens.", title_f, WHITE, anchor="mt")
    sub_y = head_y + 410
    draw_text(d, (W // 2, sub_y), "Per-frame fog probability,", sub_f, SECONDARY, anchor="mt")
    draw_text(d, (W // 2, sub_y + 80), "live on the bottom bar.", sub_f, SECONDARY, anchor="mt")

    # Place the landscape screenshot below the headline, fitting full canvas width
    margin = 60
    target_w = W - 2 * margin
    target_h = int(sh * (target_w / sw))
    src = src.resize((target_w, target_h), Image.LANCZOS)

    # Drop shadow
    shadow = Image.new("RGBA", (target_w + 80, target_h + 80), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((40, 40, target_w + 40, target_h + 40), radius=44, fill=(0, 0, 0, 200))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))

    # Round the screenshot corners
    mask = Image.new("L", (target_w, target_h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, target_w, target_h), radius=40, fill=255)

    device_x = margin
    device_y = sub_y + 280
    im.paste(shadow.convert("RGB"), (device_x - 40, device_y - 40), shadow.split()[3])
    im.paste(src, (device_x, device_y), mask)

    out = OUT / "screen_2.png"
    im.save(out)
    print(f"wrote {out}")

# ──────────────────────────────────────────────────────────────────────
# Screen 3: PDF report export
# ──────────────────────────────────────────────────────────────────────
def make_screen_3():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)

    # PDF page 1 = the 20.6%-fog session
    pdf_path = "/Users/ksc/Downloads/Telegram Desktop/feral_sessions_2026-05-03_18-20.pdf"
    doc = fitz.open(pdf_path)
    page = doc[1]
    pix = page.get_pixmap(matrix=fitz.Matrix(3, 3))
    pdf_img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

    # Headline at top
    title_f = font(150, 800)
    sub_f = font(64, 500)
    head_y = 220
    draw_text(d, (W // 2, head_y), "Export", title_f, WHITE, anchor="mt")
    draw_text(d, (W // 2, head_y + 170), "clinical reports.", title_f, WHITE, anchor="mt")
    sub_y = head_y + 410
    draw_text(d, (W // 2, sub_y), "PDF or JSON. One tap.", sub_f, SECONDARY, anchor="mt")
    draw_text(d, (W // 2, sub_y + 80), "Share with your care team.", sub_f, SECONDARY, anchor="mt")

    # Place PDF page below, fitting canvas width
    margin = 60
    pw, ph = pdf_img.size
    target_w = W - 2 * margin
    target_h = int(ph * (target_w / pw))
    pdf_img = pdf_img.resize((target_w, target_h), Image.LANCZOS)

    shadow = Image.new("RGBA", (target_w + 80, target_h + 80), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((40, 40, target_w + 40, target_h + 40), radius=18, fill=(0, 0, 0, 220))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))

    mask = Image.new("L", (target_w, target_h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, target_w, target_h), radius=14, fill=255)

    device_x = margin
    device_y = sub_y + 280
    im.paste(shadow.convert("RGB"), (device_x - 40, device_y - 40), shadow.split()[3])
    im.paste(pdf_img, (device_x, device_y), mask)

    out = OUT / "screen_3.png"
    im.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    make_screen_1()
    make_screen_2()
    make_screen_3()
