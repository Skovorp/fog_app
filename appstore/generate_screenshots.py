"""Generate 3 App Store screenshots for `Luche`.

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

    title_f = font(200, 800)
    sub_f = font(78, 500)
    pill_f = font(60, 600)

    pills = [
        ("On-device", GREEN),
        ("No wifi", ACCENT),
        ("Real-time on iPhone 16+", WHITE),
    ]
    pad_x, pad_y = 60, 30
    pill_h = pill_f.size + 2 * pad_y
    pill_gap = 36

    # Compute total block height (title 2 lines + gap + sub 2 lines + gap + pills) for vertical centering
    title_h = 2 * title_f.size + 30
    title_to_sub = 130
    sub_h = 2 * sub_f.size + 30
    sub_to_pills = 220
    pills_h = len(pills) * pill_h + (len(pills) - 1) * pill_gap
    total = title_h + title_to_sub + sub_h + sub_to_pills + pills_h
    top = (H - total) // 2

    # Title
    y = top
    draw_text(d, (W // 2, y), "Score", title_f, WHITE, anchor="mt")
    y += title_f.size + 30
    draw_text(d, (W // 2, y), "freezing of gait.", title_f, WHITE, anchor="mt")
    y += title_f.size + title_to_sub

    # Subhead
    draw_text(d, (W // 2, y), "A Parkinson's symptom,", sub_f, SECONDARY, anchor="mt")
    y += sub_f.size + 30
    draw_text(d, (W // 2, y), "from a turn-in-place test.", sub_f, SECONDARY, anchor="mt")
    y += sub_f.size + sub_to_pills

    # Pills
    for text, color in pills:
        w = text_w(d, text, pill_f) + 2 * pad_x
        x = (W - w) // 2
        d.rounded_rectangle((x, y, x + w, y + pill_h), radius=pill_h // 2, outline=color, width=4)
        draw_text(d, (W // 2, y + pill_h // 2), text, pill_f, color, anchor="mm")
        y += pill_h + pill_gap

    # Footer
    note_f = font(38, 400)
    draw_text(d, (W // 2, H - 90), "Luche · made for clinicians and researchers", note_f, TERTIARY, anchor="mb")

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
    sw, sh = src.size  # 848 × 384

    # Trim a thin strip on each side to focus on action
    cl = int(sw * 0.04)
    cr = int(sw * 0.04)
    src = src.crop((cl, 0, sw - cr, sh))
    sw, sh = src.size

    _layout_text_then_image(
        im, d, src,
        title_lines=["See freezing", "as it happens."],
        sub_lines=["Per-frame fog probability,", "live on the bottom bar."],
        out_path=OUT / "screen_2.png",
        corner_radius=42,
        image_h_ratio=0.55,
    )

# ──────────────────────────────────────────────────────────────────────
# Screen 3: PDF report export
# ──────────────────────────────────────────────────────────────────────
def make_screen_3():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)

    pdf_path = "/Users/ksc/Downloads/Telegram Desktop/feral_sessions_2026-05-03_18-20.pdf"
    doc = fitz.open(pdf_path)
    page = doc[1]
    pix = page.get_pixmap(matrix=fitz.Matrix(3, 3))
    pdf_img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

    _layout_text_then_image(
        im, d, pdf_img,
        title_lines=["Export", "clinical reports."],
        sub_lines=["PDF or JSON. One tap.", "Share with your care team."],
        out_path=OUT / "screen_3.png",
        corner_radius=14,
        image_h_ratio=0.34,  # PDF page fits canvas width naturally — no crop
    )


def _layout_text_then_image(im, d, image, title_lines, sub_lines, out_path,
                            corner_radius, image_h_ratio=0.55):
    """Centered-hero layout. The image is sized to occupy `image_h_ratio` of
    the canvas height; if its natural aspect would overflow the canvas width,
    it's center-cropped horizontally so the visible portion fills the canvas
    edge-to-edge. Top/bottom margins are equal."""
    title_f = font(180, 800)
    sub_f = font(72, 500)
    side_margin = 60

    iw, ih = image.size
    target_h = int(H * image_h_ratio)
    target_w = int(iw * (target_h / ih))
    image = image.resize((target_w, target_h), Image.LANCZOS)
    canvas_inner = W - 2 * side_margin
    if target_w > canvas_inner:
        crop_x = (target_w - canvas_inner) // 2
        image = image.crop((crop_x, 0, crop_x + canvas_inner, target_h))
        target_w = canvas_inner

    title_line_gap = 18
    title_block_h = (len(title_lines) - 1) * (title_f.size + title_line_gap) + title_f.size
    title_to_sub = 70
    sub_line_gap = 18
    sub_block_h = (len(sub_lines) - 1) * (sub_f.size + sub_line_gap) + sub_f.size
    sub_to_image = 130

    block_h = title_block_h + title_to_sub + sub_block_h + sub_to_image + target_h
    top = (H - block_h) // 2

    y = top
    for i, line in enumerate(title_lines):
        draw_text(d, (W // 2, y), line, title_f, WHITE, anchor="mt")
        y += title_f.size + (title_line_gap if i < len(title_lines) - 1 else 0)
    y += title_to_sub
    for i, line in enumerate(sub_lines):
        draw_text(d, (W // 2, y), line, sub_f, SECONDARY, anchor="mt")
        y += sub_f.size + (sub_line_gap if i < len(sub_lines) - 1 else 0)
    y += sub_to_image

    device_x = (W - target_w) // 2
    device_y = y

    shadow = Image.new("RGBA", (target_w + 80, target_h + 80), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((40, 40, target_w + 40, target_h + 40), radius=corner_radius, fill=(0, 0, 0, 200))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    mask = Image.new("L", (target_w, target_h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, target_w, target_h), radius=corner_radius, fill=255)

    im.paste(shadow.convert("RGB"), (device_x - 40, device_y - 40), shadow.split()[3])
    im.paste(image, (device_x, device_y), mask)

    im.save(out_path)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    make_screen_1()
    make_screen_2()
    make_screen_3()
