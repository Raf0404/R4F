#!/usr/bin/env python3
"""Animated English video guide to R4F (R4F BUS and R4F BOX) for YouTube.

Script › neural voice (Kokoro, video/tts.py), one file per sentence › every scene drawn frame by frame
with Pillow, its animations timed on the sentences › ffmpeg (one clip per scene, in parallel) › one video,
English subtitles (.srt), thumbnail and YouTube texts.

    python3 video/make_video_en.py             › build/video-en/R4F-guide.mp4 (+ .srt, thumbnail, youtube.txt)
    python3 video/make_video_en.py --preview   › build/video-en/preview.png (three frames per scene)
    python3 video/make_video_en.py --scene 9   › renders only scene 9 (clip in build/video-en/clips)

Needs: ffmpeg, Pillow, numpy, and the voice set up as described in video/tts.py.
"""
import hashlib
import json
import math
import multiprocessing
import os
import subprocess
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_video import (BG, CARD, CARD2, CYAN, DARK, FPS, GREY, H, LOGO, ROOT, SHOTS, W, WHITE,  # noqa: E402
                        font, mono, wrap)

OUT = os.path.join(ROOT, "build", "video-en")
CL = os.path.join(OUT, "clips")
TTS_DIR = os.path.join(ROOT, "build", "tts", "cache")
TTS_PY = os.path.join(ROOT, "build", "tts", "venv", "bin", "python")
VOICE, SPEED = "af_heart", 1.0
RATE = 24000
LEAD, GAP, TAIL, FADE = 0.6, 0.35, 1.1, 0.35

ORANGE = (240, 150, 60)
GREEN = (110, 200, 120)
PINK = (214, 96, 150)
BLUE = (90, 150, 235)
PURPLE = (165, 125, 235)
PEACH = (240, 200, 165)


# ------------------------------------------------------------------ time helpers

def clamp(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def ease(x):
    x = clamp(x)
    return 1 - (1 - x) ** 3


def ease_io(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)


def back(x):
    x = clamp(x)
    c = 1.70158
    return 1 + (c + 1) * (x - 1) ** 3 + c * (x - 1) ** 2


def prog(t, t0, d=0.5):
    return ease((t - t0) / d)


def lerp(a, b, p):
    return a + (b - a) * p


def track(keys, t):
    """keys = [(time, v1, v2, ...)], smooth interpolation between consecutive keys."""
    if t <= keys[0][0]:
        return keys[0][1:]
    for k0, k1 in zip(keys, keys[1:]):
        if t <= k1[0]:
            p = ease_io((t - k0[0]) / max(k1[0] - k0[0], 1e-6))
            return tuple(lerp(a, b, p) for a, b in zip(k0[1:], k1[1:]))
    return keys[-1][1:]


def rgba(c, a=1.0):
    return tuple(c[:3]) + (max(0, min(255, int(255 * a))),)


# ------------------------------------------------------------------ drawing helpers

class ADraw(ImageDraw.ImageDraw):
    """ImageDraw whose text honours the alpha of its colour (Pillow draws text fully opaque)."""

    def text(self, xy, text, fill=None, font=None, anchor=None, **kw):
        if fill is None or len(fill) < 4 or fill[3] >= 255:
            return super().text(xy, text, fill=fill, font=font, anchor=anchor, **kw)
        if fill[3] <= 0 or not text:
            return None
        x0, y0, x1, y1 = self.textbbox(xy, text, font=font, anchor=anchor)
        x0, y0 = int(math.floor(x0)) - 2, int(math.floor(y0)) - 2
        w, h = int(math.ceil(x1)) - x0 + 4, int(math.ceil(y1)) - y0 + 4
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).text((xy[0] - x0, xy[1] - y0), text, fill=fill[3], font=font, anchor=anchor)
        self._image.paste(Image.new("RGB", (w, h), tuple(fill[:3])), (x0, y0), mask)
        return None


class Sprite:
    def __init__(self, im):
        im = im.convert("RGBA")
        self.rgb, self.alpha, self.size = im.convert("RGB"), im.getchannel("A"), im.size

    def paste(self, fr, xy, a=1.0):
        if a <= 0:
            return
        m = self.alpha if a >= 1 else self.alpha.point(lambda v: int(v * a))
        fr.paste(self.rgb, (int(xy[0]), int(xy[1])), m)


LOGO64 = Sprite(LOGO.resize((64, 64), Image.LANCZOS))
LOGO30 = Sprite(LOGO.resize((30, 30), Image.LANCZOS))
LOGO_BIG = LOGO.resize((420, 420), Image.LANCZOS)


def make_bg():
    """Large background with two soft glows: each frame takes a slowly moving window from it."""
    big = Image.new("RGB", (W + 400, H + 300), BG)
    glow = Image.new("L", big.size, 0)
    g = ImageDraw.Draw(glow)
    g.ellipse((150, 120, 1150, 900), fill=60)
    g.ellipse((1250, 600, 2200, 1350), fill=45)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    tint = Image.new("RGB", big.size, (24, 70, 86))
    out = np.asarray(Image.composite(tint, big, glow), dtype=np.float32)
    noise = np.random.default_rng(4).normal(0, 1.6, out.shape[:2])[..., None]   # dither: no gradient banding
    return Image.fromarray(np.clip(out + noise, 0, 255).astype(np.uint8))


BGBIG = make_bg()


def bg_frame(gt):
    ox = 200 + 180 * math.sin(gt * 0.045)
    oy = 150 + 130 * math.cos(gt * 0.033)
    return BGBIG.crop((int(ox), int(oy), int(ox) + W, int(oy) + H))


def header(fr, d, section, t):
    a = prog(t, 0, 0.4)
    LOGO64.paste(fr, (70, 44), a)
    d.text((150, 76), section, font=font(30, "Medium"), fill=rgba(GREY, a), anchor="lm")


def title(d, text, t, t0=0.15, y=150, size=58):
    p = prog(t, t0, 0.6)
    d.text((120, y + (1 - p) * 24), text, font=font(size, "Bold"), fill=rgba(WHITE, p))


def pill(d, x, y, text, a, fg=DARK, bg=CYAN, size=30, anchor="l"):
    f = font(size, "Medium")
    w = d.textlength(text, font=f) + 44
    h = size + 26
    if anchor == "c":
        x -= w / 2
    elif anchor == "r":
        x -= w
    if a > 0:
        d.rounded_rectangle((x, y, x + w, y + h), h / 2, fill=rgba(bg, a))
        d.text((x + 22, y + h / 2), text, font=f, fill=rgba(fg, a), anchor="lm")
    return w, h


CURSOR = [(0, 0), (0, 38), (10, 29), (17, 45), (24, 42), (17, 27), (29, 27)]


def cursor(d, x, y, a=1.0):
    if a <= 0:
        return
    pts = [(x + px, y + py) for px, py in CURSOR]
    d.polygon([(px + 2, py + 3) for px, py in pts], fill=rgba((0, 0, 0), 0.35 * a))
    d.polygon(pts, fill=rgba(WHITE, a))
    d.line(pts + [pts[0]], fill=rgba((10, 10, 10), a), width=2)


def ripple(d, x, y, t, tc):
    q = (t - tc) / 0.6
    if 0 <= q < 1:
        r = 10 + 42 * ease(q)
        d.ellipse((x - r, y - r, x + r, y + r), outline=rgba(CYAN, 1 - q), width=5)


def bez(p0, p3, n=48):
    dx = (p3[0] - p0[0]) * 0.5
    p1, p2 = (p0[0] + dx, p0[1]), (p3[0] - dx, p3[1])
    pts = []
    for i in range(n + 1):
        u = i / n
        a, b, c, e = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u * u * (1 - u), u ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
    return pts


def path(d, pts, p, color, a=1.0, width=4, arrow=False):
    """Line drawn up to fraction p of its length."""
    if p <= 0 or a <= 0:
        return
    k = max(2, int(round((len(pts) - 1) * p)) + 1)
    d.line(pts[:k], fill=rgba(color, a), width=width, joint="curve")
    if arrow and p >= 1:
        (x0, y0), (x1, y1) = pts[-2], pts[-1]
        ang = math.atan2(y1 - y0, x1 - x0)
        s = 9 + width
        tip = (x1 + math.cos(ang) * 4, y1 + math.sin(ang) * 4)
        l = (x1 - math.cos(ang) * s + math.cos(ang + math.pi / 2) * s * 0.6,
             y1 - math.sin(ang) * s + math.sin(ang + math.pi / 2) * s * 0.6)
        r = (x1 - math.cos(ang) * s - math.cos(ang + math.pi / 2) * s * 0.6,
             y1 - math.sin(ang) * s - math.sin(ang + math.pi / 2) * s * 0.6)
        d.polygon([tip, l, r], fill=rgba(color, a))


def dots(d, pts, t, color, a=1.0, n=3, speed=0.45, r=7):
    if a <= 0:
        return
    for j in range(n):
        u = (t * speed + j / n) % 1.0
        idx = u * (len(pts) - 1)
        i0 = int(idx)
        f = idx - i0
        i1 = min(i0 + 1, len(pts) - 1)
        x = lerp(pts[i0][0], pts[i1][0], f)
        y = lerp(pts[i0][1], pts[i1][1], f)
        fade = min(1.0, u * 6, (1 - u) * 6)
        d.ellipse((x - r, y - r, x + r, y + r), fill=rgba(color, a * fade))


def clock(d, cx, cy, r, ang, a):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=rgba(GREY, a), width=3)
    d.line((cx, cy, cx + r * 0.72 * math.sin(ang), cy - r * 0.72 * math.cos(ang)), fill=rgba(WHITE, a), width=4)
    d.ellipse((cx - 4, cy - 4, cx + 4, cy + 4), fill=rgba(WHITE, a))


def check(d, x, y, s, color, a):
    d.line([(x, y + s * 0.5), (x + s * 0.38, y + s * 0.85), (x + s, y + s * 0.1)], fill=rgba(color, a),
           width=max(3, int(s / 6)), joint="curve")


def step_cards(fr, d, t, c, items, x1=W - 120, y0=290, step=152, hgt=130):
    """Numbered cards: card k appears on sentence k; the newest one is outlined."""
    active = max([k for k in range(len(items)) if t >= c.cue(k)] or [-1])
    for k, (head, sub) in enumerate(items):
        p = prog(t, c.cue(k), 0.55)
        if p <= 0:
            continue
        dx = (1 - p) * 90
        y = y0 + k * step
        d.rounded_rectangle((120 + dx, y, x1 + dx, y + hgt), 22, fill=rgba(CARD, p),
                            outline=rgba(CYAN, p if k == active else 0), width=3)
        d.ellipse((150 + dx, y + 28, 190 + dx, y + 68), fill=rgba(CYAN, p))
        d.text((170 + dx, y + 48), str(k + 1), font=font(26, "Bold"), fill=rgba(DARK, p), anchor="mm")
        d.text((218 + dx, y + 46), head, font=font(40, "Medium"), fill=rgba(WHITE, p), anchor="lm")
        d.text((218 + dx, y + 96), sub, font=font(30), fill=rgba(GREY, p), anchor="lm")


# ------------------------------------------------------------------ screenshots with camera, spotlight, cursor

_SRC = {}


def src(name):
    if name not in _SRC:
        _SRC[name] = Image.open(os.path.join(SHOTS, name)).convert("RGB")
    return _SRC[name]


class Shot:
    """A screenshot seen through a moving camera. Coordinates are those of the original image."""

    def __init__(self, name, area):
        self.im = src(name)
        self.area = area
        self.ar = (area[2] - area[0]) / (area[3] - area[1])

    def box(self, cx, cy, w):
        iw, ih = self.im.size
        w = min(w, iw)
        h = w / self.ar
        if h > ih:
            h, w = ih, ih * self.ar
        x0 = min(max(cx - w / 2, 0), iw - w)
        y0 = min(max(cy - h / 2, 0), ih - h)
        return (x0, y0, x0 + w, y0 + h)

    def draw(self, fr, d, t, cam, a=1.0, dy=0.0):
        ax0, ay0, ax1, ay1 = self.area
        ay0, ay1 = ay0 + dy, ay1 + dy
        b = self.box(*cam)
        self.s = (ax1 - ax0) / (b[2] - b[0])
        self.b, self.ay0 = b, ay0
        if a <= 0:
            return
        d.rounded_rectangle((ax0 - 9, ay0 - 9, ax1 + 9, ay1 + 9), 16, fill=rgba(CARD2, a))
        img = self.im.resize((int(ax1 - ax0), int(ay1 - ay0)), Image.BICUBIC, box=b)
        mask = None if a >= 1 else Image.new("L", img.size, int(255 * a))
        fr.paste(img, (int(ax0), int(ay0)), mask)

    def to(self, x, y):
        return (self.area[0] + (x - self.b[0]) * self.s, self.ay0 + (y - self.b[1]) * self.s)

    def rect(self, r):
        x0, y0 = self.to(r[0], r[1])
        x1, y1 = self.to(r[2], r[3])
        return (x0, y0, x1, y1)

    def spotlight(self, d, r, a, label=None, la=1.0):
        """Dims the shot outside rectangle r (original coordinates)."""
        if a <= 0:
            return
        ax0, ay0 = self.area[0], self.ay0
        ax1, ay1 = self.area[2], self.ay0 + (self.area[3] - self.area[1])
        x0, y0, x1, y1 = self.rect(r)
        x0, y0, x1, y1 = max(x0, ax0), max(y0, ay0), min(x1, ax1), min(y1, ay1)
        dim = rgba((0, 0, 0), 0.58 * a)
        d.rectangle((ax0, ay0, ax1, y0), fill=dim)
        d.rectangle((ax0, y1, ax1, ay1), fill=dim)
        d.rectangle((ax0, y0, x0, y1), fill=dim)
        d.rectangle((x1, y0, ax1, y1), fill=dim)
        d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), 12, outline=rgba(CYAN, a), width=5)
        if label:
            y = y1 + 16 if y1 + 80 < ay1 else y0 - 74
            pill(d, x0, y, label, a * la)

    def cell(self, d, cx, cy, color, p, empty=False):
        """Matrix cell (30 px in the original) that pops in."""
        if p <= 0:
            return
        x, y = self.to(cx, cy)
        hs = 15 * self.s * ((0.55 + 0.45 * back(p)) if not empty else 1)
        if empty:
            d.rounded_rectangle((x - hs, y - hs, x + hs, y + hs), 6 * self.s, fill=rgba((247, 247, 247), p),
                                outline=rgba((212, 212, 212), p), width=max(1, int(2 * self.s)))
        else:
            d.rounded_rectangle((x - hs, y - hs, x + hs, y + hs), 6 * self.s, fill=rgba(color, min(1, p * 2)))


def spot_track(keys, t, move=0.55):
    """keys = [(time, rect, label)]: the spotlight glides from one rectangle to the next."""
    if t < keys[0][0]:
        return None, 0, None, 0
    a = prog(t, keys[0][0], 0.45)
    cur = keys[0]
    rect = keys[0][1]
    for k0, k1 in zip(keys, keys[1:]):
        if t >= k1[0]:
            cur, rect = k1, k1[1]
        else:
            break
    i = keys.index(cur)
    if i > 0:
        p = ease_io((t - cur[0]) / move)
        rect = tuple(lerp(x, y, p) for x, y in zip(keys[i - 1][1], cur[1]))
    la = prog(t, cur[0] + (move * 0.6 if i > 0 else 0.2), 0.3)
    return rect, a, cur[2], la


def shot_in(t, t0=0.1):
    p = prog(t, t0, 0.6)
    return p, (1 - p) * 40


# ------------------------------------------------------------------ scenes

class Ctx:
    def __init__(self, cues, ends, dur):
        self.cues, self.ends, self.dur = cues, ends, dur

    def cue(self, i):
        return self.cues[i] if i < len(self.cues) else self.dur

    def end(self, i):
        return self.ends[i]

    def D(self, i):
        return self.ends[i] - self.cues[i]


def sc_title(fr, d, t, c):
    p = back(clamp((t - 0.1) / 0.8))
    a = clamp((t - 0.1) / 0.35)
    size = max(8, int(340 * (0.65 + 0.35 * p)))
    Sprite(LOGO_BIG.resize((size, size), Image.BILINEAR)).paste(fr, ((W - size) / 2, 300 - size / 2), a)
    q = prog(t, 0.5, 0.6)
    d.text((W / 2, 570 + (1 - q) * 30), "R4F", font=font(110, "Bold"), fill=rgba(WHITE, q), anchor="mm")
    q = prog(t, 0.8, 0.6)
    d.text((W / 2, 665 + (1 - q) * 20), "Multichannel audio for macOS", font=font(46), fill=rgba(GREY, q),
           anchor="mm")
    for k, name in enumerate(["R4F BUS", "R4F BOX"]):
        q = prog(t, c.cue(1) + 0.9 + k * 0.35, 0.5)
        pill(d, W / 2 + (-30 if k == 0 else 30), 760 + (1 - q) * 20, name, q, size=40, anchor="r" if k == 0 else "l")


def sc_two(fr, d, t, c):
    header(fr, d, "Introduction", t)
    title(d, "Two virtual devices, one app", t)
    cards = [
        ("R4F BUS", CYAN, "From your DAW to one or more audio interfaces, even with different clocks.",
         ("DAW", "interfaces")),
        ("R4F BOX", WHITE, "From one app to another, with a matrix inside the driver and no added latency.",
         ("App A", "App B")),
    ]
    for k, (name, col, desc, (a_lbl, b_lbl)) in enumerate(cards):
        p = prog(t, c.cue(0) + 0.6 + k * 0.45, 0.6)
        if p <= 0:
            continue
        x0 = 120 + k * 860 + (1 - p) * (-80 if k == 0 else 80)
        x1 = x0 + 820
        d.rounded_rectangle((x0, 290, x1, 910), 28, fill=rgba(CARD, p), outline=rgba(col, p), width=4)
        d.text((x0 + 50, 360), name, font=font(60, "Bold"), fill=rgba(col, p), anchor="lm")
        pill(d, x0 + 50, 412, "256 channels", p, bg=col, size=30)
        q = prog(t, c.cue(1 + k) + 0.2, 0.6)
        for j, line in enumerate(wrap(d, desc, font(38), 720)):
            d.text((x0 + 50, 520 + j * 52 + (1 - q) * 16), line, font=font(38), fill=rgba(WHITE, q))
        if q > 0:
            y = 800
            wa, _ = pill(d, x0 + 50, y - 28, a_lbl, q, fg=WHITE, bg=CARD2, size=28)
            wb, _ = pill(d, x1 - 50, y - 28, b_lbl, q, fg=WHITE, bg=CARD2, size=28, anchor="r")
            pts = bez((x0 + 50 + wa + 12, y), (x1 - 50 - wb - 12, y), 30)
            path(d, pts, prog(t, c.cue(1 + k) + 0.5, 0.6), col, q * 0.6, 3, arrow=True)
            dots(d, pts, t, col, prog(t, c.cue(1 + k) + 1.0, 0.4), n=3, speed=0.6, r=6)


def sc_install(fr, d, t, c):
    header(fr, d, "Installation", t)
    title(d, "Installing R4F", t)
    step_cards(fr, d, t, c, [
        ("Download the R4F installer (.pkg)", "github.com/Raf0404/R4F  ›  Releases"),
        ("Quit your DAW and open the package", "Installs the drivers, the app and the Live device"),
        ("Blocked by macOS?  «Open Anyway»", "System Settings  ›  Privacy & Security"),
        ("Allow microphone access", "R4F reads R4F BUS like an audio input"),
    ])


TRACKS = [("Main", "1-2", BLUE), ("Vocals", "3-4", GREEN), ("Drums 5.1", "5-10", ORANGE), ("Reverb", "11", PINK)]
OUTS = [("Interface A", "speakers 1-8"), ("Interface B", "headphones"), ("Mac", "built-in output")]


def sc_bus_diagram(fr, d, t, c):
    header(fr, d, "R4F BUS", t)
    title(d, "How R4F BUS works", t)
    # DAW
    p = prog(t, c.cue(0) + 0.3, 0.6)
    if p > 0:
        dx = (1 - p) * -60
        d.rounded_rectangle((110 + dx, 290, 520 + dx, 880), 24, fill=rgba(CARD, p))
        d.text((140 + dx, 335), "DAW", font=font(44, "Bold"), fill=rgba(WHITE, p), anchor="lm")
        d.text((140 + dx, 380), "Live · Logic · Reaper · …", font=font(26), fill=rgba(GREY, p), anchor="lm")
        for k, (name, ch, col) in enumerate(TRACKS):
            q = prog(t, c.cue(0) + 0.6 + k * 0.15, 0.5) * p
            y = 430 + k * 105
            d.rounded_rectangle((140 + dx, y, 490 + dx, y + 76), 14, fill=rgba(CARD2, q))
            d.rectangle((140 + dx, y + 14, 148 + dx, y + 62), fill=rgba(col, q))
            d.text((168 + dx, y + 38), name, font=font(32, "Medium"), fill=rgba(WHITE, q), anchor="lm")
            d.text((470 + dx, y + 38), ch, font=font(30, "Bold"), fill=rgba(col, q), anchor="rm")
    # R4F BUS
    pb = prog(t, c.cue(1) + 0.2, 0.6)
    if pb > 0:
        s = 0.8 + 0.2 * back(pb)
        cx, cy, hw, hh = 770, 590, 135 * s, 130 * s
        d.rounded_rectangle((cx - hw, cy - hh, cx + hw, cy + hh), 22, fill=rgba(CYAN, pb))
        d.text((cx, cy - 40), "R4F BUS", font=font(42, "Bold"), fill=rgba(DARK, pb), anchor="mm")
        d.text((cx, cy + 10), "256 channels", font=font(28, "Medium"), fill=rgba(DARK, pb), anchor="mm")
        d.text((cx, cy + 50), "virtual device", font=font(26), fill=rgba(DARK, pb), anchor="mm")
    for k, (_, _, col) in enumerate(TRACKS):
        pts = bez((490, 468 + k * 105), (635, 540 + k * 33), 30)
        q = prog(t, c.cue(1) + 0.6 + k * 0.12, 0.6)
        path(d, pts, q, col, 0.8, 4)
        dots(d, pts, t + k * 0.3, col, prog(t, c.cue(1) + 1.2, 0.4), n=2, speed=0.55, r=6)
    # app
    pa = prog(t, c.cue(2) + 0.1, 0.6)
    if pa > 0:
        d.rounded_rectangle((1010, 400, 1350, 780), 24, fill=rgba(CARD, pa), outline=rgba(CYAN, pa), width=4)
        d.text((1180, 445), "R4F app", font=font(38, "Bold"), fill=rgba(WHITE, pa), anchor="mm")
        lit = {(0, 0), (1, 1), (2, 3), (3, 2), (4, 4), (2, 4)}
        for i in range(5):
            for j in range(5):
                x, y = 1100 + j * 36, 490 + i * 36
                on = (i, j) in lit and (0.5 + 0.5 * math.sin(t * 3 + i + j)) > 0.25
                d.rounded_rectangle((x, y, x + 28, y + 28), 6, fill=rgba(CYAN if on else CARD2, pa))
        d.text((1180, 700), "routes · sum · 1:1", font=font(26), fill=rgba(GREY, pa), anchor="mm")
        pts = bez((905, 590), (1005, 590), 12)
        path(d, pts, pa, CYAN, 1, 6, arrow=True)
        dots(d, pts, t, WHITE, pa, n=2, speed=0.8, r=6)
    for k, (name, sub) in enumerate(OUTS):
        q = prog(t, c.cue(2) + 0.7 + k * 0.25, 0.55)
        if q <= 0:
            continue
        y = 330 + k * 215
        dx = (1 - q) * 60
        d.rounded_rectangle((1470 + dx, y, 1820 + dx, y + 140), 20, fill=rgba(CARD, q))
        d.text((1500 + dx, y + 48), name, font=font(34, "Bold"), fill=rgba(WHITE, q), anchor="lm")
        d.text((1500 + dx, y + 96), sub, font=font(28), fill=rgba(GREY, q), anchor="lm")
        pts = bez((1350, 590), (1465, y + 70), 30)
        path(d, pts, q, CYAN, 0.8, 4, arrow=True)
        dots(d, pts, t + k * 0.2, CYAN, prog(t, c.cue(2) + 1.2 + k * 0.25, 0.4), n=2, speed=0.55, r=6)
        qc = prog(t, c.cue(3) + 0.2 + k * 0.2, 0.5)
        clock(d, 1770 + dx, y + 70, 28, t * (2.2 + 0.35 * k), qc * q)
    qd = prog(t, c.cue(3) + 0.9, 0.5)
    pill(d, 1180, 800 + (1 - qd) * 20, "drift corrected", qd, size=30, anchor="c")


DAW_ROWS = [("Ableton Live", "Audio To  ›  Ext. Out  ›  channel"),
            ("Logic Pro", "channel strip  ›  Output  ›  Output N"),
            ("Reaper", "Route button  ›  hardware output"),
            ("Cubase · Pro Tools · Bitwig", "outputs / buses on R4F BUS channels")]


def sc_daw(fr, d, t, c):
    header(fr, d, "R4F BUS", t)
    title(d, "Connect your DAW", t)
    q = prog(t, c.cue(0) + 0.8, 0.5)
    pill(d, 120, 262 + (1 - q) * 14, "Output device:  R4F BUS", q, size=32)
    for k, (a, b) in enumerate(DAW_ROWS):
        p = prog(t, c.cue(k + 1), 0.5)
        if p <= 0:
            continue
        y = 355 + k * 110
        dx = (1 - p) * 80
        d.rounded_rectangle((120 + dx, y, W - 120 + dx, y + 94), 18, fill=rgba(CARD if k % 2 == 0 else CARD2, p))
        d.text((160 + dx, y + 47), a, font=font(40, "Bold"), fill=rgba(CYAN, p), anchor="lm")
        d.text((800 + dx, y + 47), b, font=font(38), fill=rgba(WHITE, p), anchor="lm")
    q = prog(t, c.cue(5), 0.5)
    d.text((120, 830 + (1 - q) * 14), "Channels 1-2 = main output.  Use channel 3 and up for your tracks.",
           font=font(36, "Medium"), fill=rgba(CYAN, q))


MENU_ITEMS = [
    ("R4F BUS running", "info"), ("bus: R4F BUS (256 channels)", "info"),
    ("  mac: MacBook Pro Speakers — 2 ch, ok, 22 ms", "info"), ("R4F BOX: 1:1 on 256 channels", "info"),
    ("-", ""), ("Stop", "item"), ("Restart", "item"), ("-", ""),
    ("Configure R4F BUS…", "item"), ("Configure R4F BOX…", "item"), ("Audio Devices (click = copy name)", "item"),
    ("Show Log", "item"), ("-", ""), ("Launch at Login", "item"), ("Quit R4F", "item"),
]
MX, MY, MW = 1000, 336, 760


def menu_sprite(selected):
    h = sum(14 if txt == "-" else 44 for txt, _ in MENU_ITEMS) + 24
    im = Image.new("RGBA", (MW, h), (0, 0, 0, 0))
    m = ImageDraw.Draw(im)
    m.rounded_rectangle((0, 0, MW - 1, h - 1), 16, fill=(236, 235, 233, 255))
    y, rows = 12, {}
    for text, kind in MENU_ITEMS:
        if text == "-":
            m.line((18, y + 7, MW - 18, y + 7), fill=(200, 199, 197), width=2)
            y += 14
            continue
        rows[text] = y
        sel = text == selected
        if sel:
            m.rounded_rectangle((8, y, MW - 8, y + 42), 8, fill=(64, 140, 240))
        col = (140, 140, 140) if kind == "info" else (WHITE if sel else (25, 25, 25))
        m.text((26, y + 21), text, font=font(28), fill=col, anchor="lm")
        y += 44
    return im, rows


MENU_PLAIN, MENU_ROWS = menu_sprite(None)
MENU_SEL, _ = menu_sprite("Configure R4F BUS…")


def sc_menu(fr, d, t, c):
    header(fr, d, "The R4F app", t)
    title(d, "The R4F menu", t)
    d.rectangle((0, 286, W, 330), fill=(58, 57, 55))
    LOGO30.paste(fr, (1290, 293))
    d.text((1800, 308), "Tue 17:42", font=font(26, "Medium"), fill=WHITE, anchor="rm")
    t_click = c.cue(0) + 1.0
    t_sel = c.cue(1) + 0.45 * c.D(1)
    # menu
    p = ease(clamp((t - t_click - 0.05) / 0.35))
    if p > 0:
        im = MENU_SEL if t >= t_sel else MENU_PLAIN
        hh = int(im.height * p)
        if hh > 2:
            sp = Sprite(im.crop((0, 0, MW, hh)))
            sp.paste(fr, (MX, MY))
        if t >= c.cue(1) + 0.2:
            q = prog(t, c.cue(1) + 0.2, 0.4)
            y0 = MY + MENU_ROWS["R4F BUS running"] - 4
            y1 = MY + MENU_ROWS["R4F BOX: 1:1 on 256 channels"] + 46
            d.rounded_rectangle((MX - 8, y0, MX + MW + 8, y1), 12, outline=rgba(CYAN, q), width=4)
        if t >= t_sel:
            q = prog(t, t_sel, 0.4)
            y0 = MY + MENU_ROWS["Configure R4F BUS…"] - 4
            y1 = MY + MENU_ROWS["Configure R4F BOX…"] + 46
            d.rounded_rectangle((MX - 8, y0, MX + MW + 8, y1), 12, outline=rgba(CYAN, q), width=4)
    # left texts
    q = prog(t, c.cue(0) + 0.2, 0.5)
    d.text((120, 420 + (1 - q) * 14), "In the menu bar, top right.", font=font(46, "Medium"), fill=rgba(WHITE, q))
    q = prog(t, c.cue(1) + 0.2, 0.5)
    d.text((120, 540 + (1 - q) * 14), "Live status of the bus", font=font(38), fill=rgba(GREY, q))
    d.text((120, 590 + (1 - q) * 14), "and of every output", font=font(38), fill=rgba(GREY, q))
    q = prog(t, t_sel, 0.5)
    d.text((120, 700 + (1 - q) * 14), "Configure R4F BUS… / BOX…", font=font(38, "Bold"), fill=rgba(CYAN, q))
    d.text((120, 752 + (1 - q) * 14), "settings for the bus and the box", font=font(36), fill=rgba(GREY, q))
    # cursor
    keys = [(0.3, 1500, 900), (c.cue(0) + 0.9, 1302, 304), (t_sel - 0.6, 1302, 304),
            (t_sel, MX + 330, MY + MENU_ROWS["Configure R4F BUS…"] + 14)]
    x, y = track(keys, t)
    ripple(d, 1305, 308, t, t_click)
    cursor(d, x, y, prog(t, 0.3, 0.3))


EL = "bus-elenco.png"
AREA = (100, 250, 1820, 1000)


def sc_outputs(fr, d, t, c):
    header(fr, d, "R4F BUS · Editor", t)
    title(d, "Outputs", t)
    sh = Shot(EL, AREA)
    a, dy = shot_in(t)
    cam = track([(0, 960, 820, 1920), (c.cue(0) + 0.8, 960, 820, 1920), (c.cue(0) + 2.2, 600, 560, 1180)], t)
    sh.draw(fr, d, t, cam, a, dy)
    t_click = c.cue(0) + 2.9
    bx, by = sh.to(148, 686)
    keys = [(c.cue(0) + 1.8, bx + 520, by + 160), (t_click - 0.1, bx + 8, by - 4)]
    ca = prog(t, c.cue(0) + 1.8, 0.3) * (1 - prog(t, c.cue(1), 0.3))
    if ca > 0:
        x, y = track(keys, t)
        ripple(d, bx + 8, by - 4, t, t_click)
        q = prog(t, t_click + 0.1, 0.4) * (1 - prog(t, c.cue(1), 0.3))
        pill(d, sh.to(262, 0)[0] + 14, by - 28, "new output", q)
        cursor(d, x, y, ca)
    rect, sa, label, la = spot_track([
        (c.cue(1) + 0.1, (32, 540, 272, 655), "short name: automatic"),
        (c.cue(1) + 0.55 * c.D(1), (32, 540, 1008, 655), "named after the device"),
    ], t)
    if rect:
        sh.spotlight(d, rect, sa, label, la)


def sc_routes(fr, d, t, c):
    header(fr, d, "R4F BUS · Editor", t)
    title(d, "Routes", t)
    sh = Shot(EL, AREA)
    a, dy = shot_in(t)
    cam = track([(0, 960, 900, 1920), (c.cue(0) + 0.3, 960, 900, 1920), (c.cue(0) + 1.4, 960, 1050, 1860)], t)
    sh.draw(fr, d, t, cam, a, dy)
    D0 = c.D(0)
    rect, sa, label, la = spot_track([
        (c.cue(0) + 0.30 * D0, (296, 905, 470, 1190), "bus channels"),
        (c.cue(0) + 0.52 * D0, (526, 905, 742, 1190), "output"),
        (c.cue(0) + 0.74 * D0, (746, 905, 920, 1190), "output channels"),
        (c.cue(1) + 0.2, (1322, 905, 1745, 1190), "connections, or the error in red"),
    ], t)
    if rect:
        sh.spotlight(d, rect, sa, label, la)


def sc_mode(fr, d, t, c):
    header(fr, d, "R4F BUS · Editor", t)
    title(d, "Sum or 1:1", t)
    sh = Shot(EL, (100, 250, 1820, 560))
    a, dy = shot_in(t)
    sh.draw(fr, d, t, (950, 1050, 1860), a, dy)
    sa = prog(t, c.cue(0) + 0.2, 0.45)
    sh.spotlight(d, (934, 902, 1180, 1190), sa)
    boxes = [(100, 640, 940, 965, "Sum", "every input to every output, each at 1/N", c.cue(0) + 0.4,
              [(0, 0), (0, 1), (1, 0), (1, 1)], CYAN),
             (980, 640, 1820, 965, "One-to-one", "in pairs: L to 1, R to 2", c.cue(1) + 0.2,
              [(0, 0), (1, 1)], ORANGE)]
    for x0, y0, x1, y1, name, sub, t0, links, col in boxes:
        p = prog(t, t0, 0.6)
        if p <= 0:
            continue
        dyy = (1 - p) * 30
        d.rounded_rectangle((x0, y0 + dyy, x1, y1 + dyy), 24, fill=rgba(CARD, p))
        d.text((x0 + 36, y0 + 48 + dyy), name, font=font(42, "Bold"), fill=rgba(col, p), anchor="lm")
        d.text((x0 + 36, y0 + 96 + dyy), sub, font=font(30), fill=rgba(GREY, p), anchor="lm")
        ins = [(x0 + 210, y0 + 175 + dyy), (x0 + 210, y0 + 265 + dyy)]
        outs = [(x1 - 210, y0 + 175 + dyy), (x1 - 210, y0 + 265 + dyy)]
        for k, lbl in enumerate(["L", "R"]):
            d.text((ins[k][0] - 30, ins[k][1]), lbl, font=font(34, "Bold"), fill=rgba(WHITE, p), anchor="rm")
            d.text((outs[k][0] + 30, outs[k][1]), str(k + 1), font=font(34, "Bold"), fill=rgba(WHITE, p),
                   anchor="lm")
        for j, (i, o) in enumerate(links):
            pts = bez((ins[i][0] + 14, ins[i][1]), (outs[o][0] - 14, outs[o][1]), 36)
            path(d, pts, prog(t, t0 + 0.5 + j * 0.15, 0.6), col, p * 0.75, 4)
            dots(d, pts, t + j * 0.37, col, prog(t, t0 + 1.2, 0.4) * p, n=2, speed=0.5, r=6)
        for pt in ins + outs:
            d.ellipse((pt[0] - 12, pt[1] - 12, pt[0] + 12, pt[1] + 12), fill=rgba(WHITE, p))
        if name == "Sum":
            q = prog(t, t0 + 1.4, 0.4)
            for k in range(2):
                d.text((outs[k][0] + 60, outs[k][1]), "(L+R)/2", font=font(26), fill=rgba(GREY, q), anchor="lm")
    q = prog(t, c.cue(2) + 0.3, 0.5)
    w = 640
    d.rounded_rectangle((W / 2 - w / 2, 990 + (1 - q) * 40, W / 2 + w / 2, 1052 + (1 - q) * 40), 31,
                        fill=rgba(CYAN, q))
    check(d, W / 2 - w / 2 + 30, 1008 + (1 - q) * 40, 26, DARK, q)
    d.text((W / 2 + 18, 1021 + (1 - q) * 40), "Save and Apply  ›  routing updated", font=font(32, "Medium"),
           fill=rgba(DARK, q), anchor="mm")


MAT = "bus-matrice.png"


def mcell(col, row):
    return (154 + 36 * col, 1066 + 36 * row)


def sc_matrix(fr, d, t, c):
    header(fr, d, "R4F BUS · Matrix", t)
    title(d, "The matrix", t)
    sh = Shot(MAT, AREA)
    a, dy = shot_in(t)
    cam = track([(0, 700, 1270, 1400), (c.cue(0) + 0.5, 700, 1270, 1400), (c.cue(1), 525, 1385, 1050)], t)
    sh.draw(fr, d, t, cam, a, dy)
    q = prog(t, c.cue(0) + 0.45 * c.D(0), 0.4) * (1 - prog(t, c.cue(1), 0.4))
    x, y = sh.to(60, 1180)
    pill(d, x, y, "rows: bus channels", q)
    x, y = sh.to(215, 960)
    pill(d, x, y - 10, "columns: outputs", prog(t, c.cue(0) + 0.65 * c.D(0), 0.4) * (1 - prog(t, c.cue(1), 0.4)))
    D1 = max(c.D(1), 3.2)
    t_click = c.cue(1) + 0.25 * D1
    t_drag0, t_drag1 = c.cue(1) + 0.55 * D1, c.cue(1) + 0.95 * D1
    sh.cell(d, *mcell(14, 11), PURPLE, prog(t, t_click, 0.35))
    for k in range(4):
        sh.cell(d, *mcell(14 + k, 12 + k), PURPLE, prog(t, lerp(t_drag0, t_drag1, k / 3), 0.3))
    p1, p2, p3 = mcell(14, 11), mcell(14, 12), mcell(17, 15)
    keys = [(c.cue(1) - 0.3, p1[0] + 320, p1[1] + 120), (t_click - 0.05, *p1), (t_drag0 - 0.1, *p2),
            (t_drag0, *p2), (t_drag1, *p3)]
    cx, cy = track(keys, t)
    sx, sy = sh.to(cx, cy)
    ripple(d, *sh.to(*p1), t, t_click)
    ca = prog(t, c.cue(1) - 0.3, 0.3)
    cursor(d, sx, sy, ca)
    q = prog(t, t_click + 0.2, 0.4)
    x, y = sh.to(p1[0] + 40, p1[1] - 60)
    pill(d, x, y, "click: connect", q * (1 - prog(t, t_drag0, 0.3)))
    q = prog(t, t_drag1, 0.4)
    x, y = sh.to(p3[0] + 40, p3[1] - 30)
    pill(d, x, y, "drag: many at once", q)


CODE = ["Main: 1-2 => mac:1-2",
        "5.1: 3-8 => blackhole:1,3,2,5-6,4",
        "Vocals: 9-10 -> blackhole:7-8",
        "Reverb: 11 -> blackhole:9-12 @-3"]


def code_tokens(line):
    name, rest = line.split(": ", 1)
    out = [(name + ":", CYAN), (" ", WHITE)]
    for j, tok in enumerate(rest.split(" ")):
        if j:
            out.append((" ", WHITE))
        col = ORANGE if tok == "->" else PURPLE if tok == "=>" else GREEN if tok.startswith("@") else WHITE
        out.append((tok, col))
    return out


def sc_text(fr, d, t, c):
    header(fr, d, "R4F BUS · Text", t)
    title(d, "The text view", t)
    p = prog(t, 0.15, 0.6)
    x0, y0, x1, y1 = 160, 270 + (1 - p) * 30, 1760, 700 + (1 - p) * 30
    d.rounded_rectangle((x0, y0, x1, y1), 24, fill=rgba((20, 21, 23), p), outline=rgba(CARD2, p), width=3)
    for k, col in enumerate([(240, 95, 90), (245, 190, 70), (100, 200, 95)]):
        d.ellipse((x0 + 30 + k * 34, y0 + 26, x0 + 50 + k * 34, y0 + 46), fill=rgba(col, p))
    d.text((x0 + 150, y0 + 36), "one route per line", font=font(26), fill=rgba(GREY, p), anchor="lm")
    f = mono(44)
    cw = f.getlength("M")
    total = sum(len(l) for l in CODE)
    typed = int(total * clamp((t - c.cue(0) - 0.4) / max(0.8 * c.D(0), 1.5)))
    shown = typed
    lx, ly = x0 + 50, y0 + 100
    caret = None
    pos = {}
    for i, line in enumerate(CODE):
        n = min(len(line), shown)
        shown -= n
        col_i = 0
        for tok, col in code_tokens(line):
            for ch in tok:
                if col_i < n:
                    d.text((lx + col_i * cw, ly + i * 70), ch, font=f, fill=rgba(col, p))
                col_i += 1
        idx = 0
        for tok, _ in code_tokens(line):
            pos.setdefault(tok, []).append((lx + idx * cw, ly + i * 70, len(tok) * cw))
            idx += len(tok)
        if n < len(line) and caret is None:
            caret = (lx + n * cw, ly + i * 70)
    if caret is None:
        caret = (lx + len(CODE[-1]) * cw, ly + (len(CODE) - 1) * 70)
    if (t * 2) % 1 < 0.6 and t < c.cue(1) + 0.5:
        d.rectangle((caret[0] + 2, caret[1] + 4, caret[0] + 6, caret[1] + 52), fill=rgba(CYAN, p))
    # highlights and legend
    legend = [("->", "sum", ORANGE, c.cue(1) + 0.3), ("=>", "one-to-one", PURPLE, c.cue(1) + 0.55 * c.D(1)),
              ("@-3", "gain in dB", GREEN, c.cue(2) + 0.3)]
    lxp = 160
    for tok, what, col, t0 in legend:
        q = prog(t, t0, 0.45)
        for (x, y, w) in pos.get(tok, []):
            d.rounded_rectangle((x - 8, y - 4, x + w + 8, y + 58), 10, outline=rgba(col, q), width=4)
        if q > 0:
            fw = font(36, "Medium")
            wt = mono(40).getlength(tok) + d.textlength(what, font=fw) + 90
            yy = 770 + (1 - q) * 20
            d.rounded_rectangle((lxp, yy, lxp + wt, yy + 76), 38, fill=rgba(CARD, q), outline=rgba(col, q), width=3)
            d.text((lxp + 30, yy + 38), tok, font=mono(40), fill=rgba(col, q), anchor="lm")
            d.text((lxp + 50 + mono(40).getlength(tok), yy + 38), what, font=fw, fill=rgba(WHITE, q), anchor="lm")
        lxp += (mono(40).getlength(tok) + d.textlength(what, font=font(36, "Medium")) + 130)


def sc_presets(fr, d, t, c):
    header(fr, d, "R4F BUS · Presets", t)
    title(d, "Presets", t)
    names = ["Stereo", "Quad", "5.1", "7.1", "Ambisonics"]
    st = min(0.45, max(0.2, (c.D(0) - 1) / 6))
    for k, n in enumerate(names):
        q = back(clamp((t - c.cue(0) - 0.3 - k * st) / 0.45))
        a = clamp((t - c.cue(0) - 0.3 - k * st) / 0.2)
        if a <= 0:
            continue
        fsz = int(40 * (0.7 + 0.3 * q))
        pill(d, 120, 300 + k * 110, n, a, size=fsz)
    sh = Shot("preset.png", (760, 290, 1800, 929))
    p = prog(t, 0.2, 0.7)
    sh.area = (760 + (1 - p) * 200, 290, 1800 + (1 - p) * 200, 929)
    sh.draw(fr, d, t, (560, 344, 1120), p)
    rect, sa, label, la = spot_track([
        (c.cue(1) + 0.2, (28, 160, 1062, 278), "channel order: DAW / speakers"),
        (c.cue(1) + 0.6 * c.D(1), (28, 480, 1062, 584), "the resulting connections"),
    ], t)
    if rect:
        sh.spotlight(d, rect, sa, label, la)


def sc_box_diagram(fr, d, t, c):
    header(fr, d, "R4F BOX", t)
    title(d, "How R4F BOX works", t)
    rows = [430 + i * 72 for i in range(6)]
    xo, xi = 790, 1130
    pb = prog(t, c.cue(0) + 0.2, 0.6)
    if pb > 0:
        s = 0.85 + 0.15 * back(pb)
        cx, cy, hw, hh = 960, 590, 300 * s, 300 * s
        d.rounded_rectangle((cx - hw, cy - hh, cx + hw, cy + hh), 28, fill=rgba((22, 42, 50), pb),
                            outline=rgba(CYAN, pb), width=4)
        d.text((960, 335), "R4F BOX · 256 channels", font=font(36, "Bold"), fill=rgba(CYAN, pb), anchor="mm")
        d.text((xo, 385), "outputs", font=font(26, "Medium"), fill=rgba(GREY, pb), anchor="mm")
        d.text((xi, 385), "inputs", font=font(26, "Medium"), fill=rgba(GREY, pb), anchor="mm")
        for i, y in enumerate(rows):
            d.text((xo - 36, y), str(i + 1), font=font(28, "Medium"), fill=rgba(WHITE, pb), anchor="rm")
            d.text((xi + 36, y), str(i + 1), font=font(28, "Medium"), fill=rgba(WHITE, pb), anchor="lm")
    for i, y in enumerate(rows):
        pts = bez((xo + 14, y), (xi - 14, y), 20)
        q = prog(t, c.cue(2) + 0.2 + i * 0.12, 0.5)
        path(d, pts, q, CYAN, 0.9, 4)
        dots(d, pts, t + i * 0.21, WHITE, prog(t, c.cue(2) + 1.0, 0.4), n=2, speed=0.6, r=5)
    for i, y in enumerate(rows):
        for x in (xo, xi):
            d.ellipse((x - 11, y - 11, x + 11, y + 11), fill=rgba(WHITE, pb))
    apps = [(110, 510, "App A", "e.g. DAW, synth", "output:  R4F BOX", c.cue(1) + 0.1),
            (1410, 1810, "App B", "e.g. recorder, streaming", "input:  R4F BOX", c.cue(1) + 0.5 * c.D(1))]
    for k, (x0, x1, name, sub, io, t0) in enumerate(apps):
        p = prog(t, t0, 0.6)
        if p <= 0:
            continue
        dx = (1 - p) * (-60 if k == 0 else 60)
        d.rounded_rectangle((x0 + dx, 420, x1 + dx, 760), 24, fill=rgba(CARD, p))
        d.text((x0 + 36 + dx, 480), name, font=font(44, "Bold"), fill=rgba(WHITE, p), anchor="lm")
        d.text((x0 + 36 + dx, 536), sub, font=font(28), fill=rgba(GREY, p), anchor="lm")
        d.text((x0 + 36 + dx, 690), io, font=font(30, "Medium"), fill=rgba(CYAN, p), anchor="lm")
        for i, y in enumerate(rows):
            pts = bez((x1 + 4, 590), (xo - 16, y), 30) if k == 0 else bez((xi + 16, y), (x0 - 4, 590), 30)
            path(d, pts, prog(t, t0 + 0.4 + i * 0.06, 0.5), CYAN, 0.55, 3)
            if k == 0 or t >= c.cue(2) + 1.0:
                dots(d, pts, t + i * 0.17, CYAN, prog(t, (t0 if k == 0 else c.cue(2)) + 1.0, 0.4), n=1,
                     speed=0.5, r=5)
    q = prog(t, c.cue(2) + 1.1, 0.5)
    pill(d, 960, 830 + (1 - q) * 20, "1:1 by default", q, anchor="c")


BOXM = "box-matrice.png"


def bcell(col, row):
    return (154 + 36 * col, 748 + 36 * row)


def sc_box_matrix(fr, d, t, c):
    header(fr, d, "R4F BOX · Matrix", t)
    title(d, "The R4F BOX matrix", t)
    sh = Shot(BOXM, AREA)
    a, dy = shot_in(t)
    cam = track([(0, 700, 950, 1400), (c.cue(0) + 0.3, 700, 950, 1400), (c.cue(0) + 1.6, 470, 900, 1000)], t)
    sh.draw(fr, d, t, cam, a, dy)
    D0 = max(c.D(0), 3.0)
    t1, t2 = c.cue(0) + 0.45 * D0, c.cue(0) + 0.85 * D0
    sum_c, mute_c = bcell(0, 6), bcell(7, 7)
    sh.cell(d, *sum_c, PEACH, prog(t, t1, 0.35))
    sh.cell(d, *mute_c, None, prog(t, t2, 0.3), empty=True)
    keys = [(c.cue(0) + 0.6, sum_c[0] + 420, sum_c[1] + 200), (t1 - 0.05, *sum_c), (t2 - 0.05, *mute_c),
            (c.cue(1) + 0.6, mute_c[0] + 500, mute_c[1] + 260)]
    cx, cy = track(keys, t)
    ripple(d, *sh.to(*sum_c), t, t1)
    ripple(d, *sh.to(*mute_c), t, t2)
    cursor(d, *sh.to(cx, cy), prog(t, c.cue(0) + 0.6, 0.3) * (1 - prog(t, c.cue(1) + 0.4, 0.3)))
    x, y = sh.to(sum_c[0] + 30, sum_c[1] + 20)
    pill(d, x, y, "sum into in 1", prog(t, t1 + 0.15, 0.35) * (1 - prog(t, c.cue(1), 0.3)))
    x, y = sh.to(mute_c[0] + 30, mute_c[1] + 20)
    pill(d, x, y, "mute", prog(t, t2 + 0.15, 0.35) * (1 - prog(t, c.cue(1), 0.3)))
    badges = ["inside the driver", "no added latency", "works with the app closed"]
    for k, b in enumerate(badges):
        q = prog(t, c.cue(1) + 0.2 + k * max(0.5, c.D(1) * 0.22), 0.45)
        pill(d, 1790 + (1 - q) * 40, 300 + k * 78, b, q, size=34, anchor="r")


def sc_device(fr, d, t, c):
    header(fr, d, "Ableton Live", t)
    title(d, "The R4F Out device", t)
    step_cards(fr, d, t, c, [
        ("Drop it on a track", "User Library  ›  Max Audio Effect  ›  R4F"),
        ("Type the destinations", "e.g.  mac:1-2   or   fireface:3-4 blackhole:1@-6"),
        ("It does the rest", "free bus channel, Audio To, saved in the Set"),
    ], x1=980, y0=300, step=165, hgt=136)
    p = prog(t, c.cue(0) + 0.5, 0.55)
    if p <= 0:
        return
    x0, x1 = 1040, 1800
    y0 = 330 - (1 - p) * 90
    d.rounded_rectangle((x0 + 8, y0 + 14, x1 + 8, y0 + 470 + 14), 18, fill=rgba((0, 0, 0), 0.35 * p))
    d.rounded_rectangle((x0, y0, x1, y0 + 470), 18, fill=rgba((62, 62, 62), p))
    d.rounded_rectangle((x0, y0, x1, y0 + 60), 18, fill=rgba((44, 44, 44), p))
    d.rectangle((x0, y0 + 40, x1, y0 + 60), fill=rgba((44, 44, 44), p))
    d.ellipse((x0 + 22, y0 + 19, x0 + 44, y0 + 41), fill=rgba((250, 196, 60), p))
    d.text((x0 + 62, y0 + 30), "R4F Out", font=font(32, "Bold"), fill=rgba(WHITE, p), anchor="lm")
    d.text((x0 + 34, y0 + 100), "Destinations", font=font(28), fill=rgba(GREY, p), anchor="lm")
    txt = "mac:1-2  blackhole:3-4@-6"
    n = int(len(txt) * clamp((t - c.cue(1) - 0.5) / max(0.6 * c.D(1), 1.2)))
    typing = c.cue(1) + 0.3 <= t < c.cue(2)
    d.rounded_rectangle((x0 + 30, y0 + 130, x1 - 30, y0 + 200), 10, fill=rgba((26, 26, 26), p),
                        outline=rgba(ORANGE if typing else (90, 90, 90), p), width=3)
    f = mono(34)
    d.text((x0 + 50, y0 + 165), txt[:n], font=f, fill=rgba(CYAN, p), anchor="lm")
    if typing and (t * 2) % 1 < 0.6:
        cx = x0 + 52 + f.getlength(txt[:n])
        d.rectangle((cx, y0 + 145, cx + 4, y0 + 185), fill=rgba(WHITE, p))
    status = [("bus channels", "3-4"), ("Audio To", "Ext. Out 3/4"), ("saved in the Set", None)]
    for k, (lbl, val) in enumerate(status):
        q = prog(t, c.cue(2) + 0.3 + k * 0.45, 0.4) * p
        y = y0 + 260 + k * 62
        d.text((x0 + 34, y), lbl, font=font(30), fill=rgba(GREY, q), anchor="lm")
        if val:
            d.text((x0 + 330, y), val, font=font(30, "Medium"), fill=rgba(WHITE, q), anchor="lm")
        else:
            check(d, x0 + 330, y - 14, 28, GREEN, q)


def sc_end(fr, d, t, c):
    p = back(clamp((t - 0.1) / 0.8))
    a = clamp((t - 0.1) / 0.35)
    size = max(8, int(260 * (0.65 + 0.35 * p)))
    Sprite(LOGO_BIG.resize((size, size), Image.BILINEAR)).paste(fr, ((W - size) / 2, 250 - size / 2), a)
    q = prog(t, 0.4, 0.6)
    d.text((W / 2, 445 + (1 - q) * 24), "R4F", font=font(90, "Bold"), fill=rgba(WHITE, q), anchor="mm")
    q = prog(t, c.cue(0) + 0.6, 0.5)
    d.text((W / 2, 530 + (1 - q) * 16), "Free and open source  ·  GPL-3.0", font=font(40), fill=rgba(GREY, q),
           anchor="mm")
    url = "github.com/Raf0404/R4F"
    q = prog(t, c.cue(1) + 0.2, 0.5)
    if q > 0:
        f = font(58, "Bold")
        w = d.textlength(url, font=f) + 90
        d.rounded_rectangle((W / 2 - w / 2, 610, W / 2 + w / 2, 712), 51, outline=rgba(CYAN, q), width=4,
                            fill=rgba(CARD, q))
        n = int(len(url) * clamp((t - c.cue(1) - 0.4) / 1.4))
        d.text((W / 2 - w / 2 + 45, 661), url[:n], font=f, fill=rgba(CYAN, q), anchor="lm")
        q2 = prog(t, c.cue(1) + 1.6, 0.5)
        d.text((W / 2, 765), "installer and full guide", font=font(34), fill=rgba(GREY, q2), anchor="mm")
    q = prog(t, c.cue(2), 0.5)
    d.text((W / 2, 880 + (1 - q) * 16), "Thanks for watching!", font=font(48, "Medium"), fill=rgba(WHITE, q),
           anchor="mm")


# (chapter, sentences shown in the subtitles, drawing function)
SCENES = [
    ("Introduction", ["This is R4F: multichannel audio for macOS.",
                      "In this video, you'll see how to use R4F BUS and R4F BOX."], sc_title),
    ("Introduction", ["R4F installs two virtual audio devices, with 256 channels each.",
                      "R4F BUS takes the tracks from your DAW to one or more audio interfaces.",
                      "R4F BOX passes audio from one app to another."], sc_two),
    ("Installation", ["To install it, download the package from the Releases page on GitHub.",
                      "Quit your DAW, then open the file.",
                      "If macOS blocks it, go to System Settings, Privacy and Security, and click Open Anyway.",
                      "On first launch, allow microphone access: R4F needs it to read the bus."], sc_install),
    ("How R4F BUS works", ["Here's how R4F BUS works.",
                           "Your DAW plays into R4F BUS, one track per channel.",
                           "The R4F app reads the bus and sends each channel to the audio interfaces you choose.",
                           "It also corrects the drift between their clocks, even when they're not in sync."],
     sc_bus_diagram),
    ("How R4F BUS works", ["In your DAW, choose R4F BUS as the output device, then send each track to its own channel.",
                           "In Ableton Live, use Audio To, Ext. Out.",
                           "In Logic Pro, use the Output slot.",
                           "In Reaper, the Route button.",
                           "Cubase, Pro Tools and Bitwig work the same way, with their outputs or buses.",
                           "Channels 1 and 2 are usually your main output."], sc_daw),
    ("The R4F BUS editor", ["R4F lives in the menu bar.",
                            "From here you can check its status, and open the settings for the bus and the box."],
     sc_menu),
    ("The R4F BUS editor", ["In the R4F BUS editor, first add the audio interfaces you want to play on.",
                            "Each one gets a short name automatically, based on the device, like mac or blackhole."],
     sc_outputs),
    ("The R4F BUS editor", ["Then add the routes: which bus channels go to which output, and to which of its channels.",
                            "Each row shows right away how many connections it makes, or the error in red."],
     sc_routes),
    ("The R4F BUS editor", ["In Sum mode, every channel goes to all the outputs of the route, "
                            "each one lowered so the level never rises.",
                            "One-to-one mode connects them in pairs, like a stereo signal.",
                            "Click Save and Apply, and the routing changes immediately."], sc_mode),
    ("Matrix, text and presets", ["The matrix view shows everything at a glance: bus channels in rows, "
                                  "outputs in columns.",
                                  "Click a cell to connect it, or drag to connect many at once."], sc_matrix),
    ("Matrix, text and presets", ["If you'd rather type, use the text view: one route per line.",
                                  "A single arrow means sum, a double arrow means one-to-one.",
                                  "Add an @ sign and a number to set the gain in dB."], sc_text),
    ("Matrix, text and presets", ["Presets build stereo, quad, 5.1, 7.1 and Ambisonics routes in one click.",
                                  "You choose the channel order in your DAW and on your speakers, "
                                  "and R4F does the mapping."], sc_presets),
    ("R4F BOX", ["R4F BOX moves audio between apps.",
                 "One app plays into the outputs of the box, and another records from its inputs.",
                 "By default, each output goes to its matching input."], sc_box_diagram),
    ("R4F BOX", ["In Configure R4F BOX, you can move, sum or mute channels.",
                 "The matrix runs inside the driver: no added latency, and it keeps working even when the app "
                 "is closed."], sc_box_matrix),
    ("Ableton Live", ["If you use Ableton Live, there's also the R4F Out device.",
                      "Drop it on a track and type the destinations.",
                      "It picks a free bus channel, sets the track's output, and saves everything in your Set."],
     sc_device),
    ("Where to get it", ["R4F is free and open source.",
                         "You'll find the installer and the full guide at github.com/Raf0404/R4F.",
                         "Thanks for watching!"], sc_end),
]


def spoken(text):
    for a, b in [("github.com/Raf0404/R4F", "github dot com, slash Raf zero four zero four, slash R4F"),
                 ("an @ sign", "an at sign"), ("in dB", "in decibels"), ("Ext. Out", "Ext Out")]:
        text = text.replace(a, b)
    return text


# ------------------------------------------------------------------ audio and timing

def tts_path(text):
    h = hashlib.sha1(f"{VOICE}|{SPEED}|{text}".encode()).hexdigest()[:16]
    return os.path.join(TTS_DIR, f"{h}.wav")


def synthesize():
    jobs = [[spoken(s), tts_path(spoken(s))] for _, lines, _ in SCENES for s in lines]
    if all(os.path.exists(p) for _, p in jobs):
        return
    os.makedirs(OUT, exist_ok=True)
    jf = os.path.join(OUT, "tts-jobs.json")
    json.dump(jobs, open(jf, "w"))
    subprocess.run([TTS_PY, "-I", os.path.join(ROOT, "video", "tts.py"), jf, VOICE, str(SPEED)], check=True)


def read_wav(p):
    with wave.open(p) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)


def timing():
    """Per scene: start, duration, sentence cues and ends, audio."""
    out, start = [], 0.0
    for _, lines, _ in SCENES:
        waves = [read_wav(tts_path(spoken(s))) for s in lines]
        cues, ends, tt = [], [], LEAD
        for wv in waves:
            cues.append(tt)
            tt += len(wv) / RATE
            ends.append(tt)
            tt += GAP
        dur = math.ceil((ends[-1] + TAIL) * FPS) / FPS
        audio = np.zeros(int(round(dur * RATE)), dtype=np.int16)
        for cu, wv in zip(cues, waves):
            i = int(round(cu * RATE))
            audio[i:i + len(wv)] = wv[:len(audio) - i]
        out.append(dict(start=start, dur=dur, cues=cues, ends=ends, audio=audio))
        start += dur
    return out


TIM = None


def render_frame(i, t):
    chapter, lines, fn = SCENES[i]
    tm = TIM[i]
    c = Ctx(tm["cues"], tm["ends"], tm["dur"])
    fr = bg_frame(tm["start"] + t)
    clean = fr.copy() if t > tm["dur"] - FADE else None
    d = ADraw(fr, "RGBA")
    fn(fr, d, t, c)
    if clean is not None:
        fr = Image.blend(clean, fr, clamp((tm["dur"] - t) / FADE))
    return fr


def render_scene(i):
    tm = TIM[i]
    wav = os.path.join(CL, f"{i:02d}.wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(tm["audio"].tobytes())
    clip = os.path.join(CL, f"{i:02d}.mp4")
    n = int(round(tm["dur"] * FPS))
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                           "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", wav,
                           "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                           "-af", "apad", "-t", f"{tm['dur']:.3f}", clip], stdin=subprocess.PIPE)
    for k in range(n):
        ff.stdin.write(render_frame(i, k / FPS).tobytes())
    ff.stdin.close()
    if ff.wait():
        raise RuntimeError(f"ffmpeg failed on scene {i}")
    return i, tm["dur"]


def ts(t, srt=True):
    h, m, s = int(t // 3600), int(t % 3600 // 60), t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",") if srt else f"{m}:{int(s):02d}"


def sub_lines(s, width=44):
    if len(s) <= width:
        return s
    words, best = s.split(), None
    for k in range(1, len(words)):
        a, b = " ".join(words[:k]), " ".join(words[k:])
        score = max(len(a), len(b))
        if best is None or score < best[0]:
            best = (score, a + "\n" + b)
    return best[1]


def thumbnail():
    img = bg_frame(3.0)
    d = ADraw(img, "RGBA")
    Sprite(LOGO_BIG).paste(img, (150, 330))
    d.text((660, 380), "R4F BUS", font=font(150, "Bold"), fill=CYAN)
    d.text((660, 550), "R4F BOX", font=font(150, "Bold"), fill=WHITE)
    d.text((665, 760), "Multichannel audio for macOS", font=font(62, "Medium"), fill=GREY)
    pill(d, 665, 860, "QUICK GUIDE", 1, size=52)
    return img.resize((1280, 720), Image.LANCZOS)


def preview():
    shots = []
    for i, (_, lines, _) in enumerate(SCENES):
        tm = TIM[i]
        for t in (tm["cues"][0] + 0.9, tm["cues"][len(lines) // 2] + 1.6, tm["dur"] - FADE - 0.05):
            shots.append(render_frame(i, min(t, tm["dur"] - FADE - 0.05)).resize((480, 270), Image.BILINEAR))
    cols = 6
    rows = math.ceil(len(shots) / cols)
    sheet = Image.new("RGB", (cols * 488 + 8, rows * 278 + 8), (90, 90, 90))
    for k, s in enumerate(shots):
        sheet.paste(s, (8 + (k % cols) * 488, 8 + (k // cols) * 278))
    sheet.save(os.path.join(OUT, "preview.png"))
    print("preview:", os.path.join(OUT, "preview.png"))


def main():
    global TIM
    os.makedirs(CL, exist_ok=True)
    synthesize()
    TIM = timing()
    if "--preview" in sys.argv:
        preview()
        return
    if "--frame" in sys.argv:
        i, t = int(sys.argv[sys.argv.index("--frame") + 1]), float(sys.argv[sys.argv.index("--frame") + 2])
        out = os.path.join(OUT, f"frame-{i:02d}-{t:.1f}.png")
        render_frame(i, t).save(out)
        print(out)
        return
    if "--scene" in sys.argv:
        print(render_scene(int(sys.argv[sys.argv.index("--scene") + 1])))
        return
    ctx = multiprocessing.get_context("fork")
    with ctx.Pool(min(8, os.cpu_count() or 4)) as pool:
        for i, dur in pool.imap_unordered(render_scene, range(len(SCENES))):
            print(f"scene {i + 1:2d}/{len(SCENES)}  {dur:5.1f} s  {SCENES[i][0]}", flush=True)

    lst = os.path.join(OUT, "clips.txt")
    open(lst, "w").write("".join(f"file '{os.path.join(CL, f'{i:02d}.mp4')}'\n" for i in range(len(SCENES))))
    final = os.path.join(OUT, "R4F-guide.mp4")
    joined = os.path.join(OUT, "joined.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy",
                    joined], check=True)
    # loudness for YouTube (-14 LUFS); the picture is copied unchanged
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", joined, "-c:v", "copy",
                    "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
                    "-movflags", "+faststart", final], check=True)
    os.remove(joined)

    srt, chapters = [], []
    for (chapter, lines, _), tm in zip(SCENES, TIM):
        for s, a, b in zip(lines, tm["cues"], tm["ends"]):
            srt.append((tm["start"] + a, tm["start"] + b + 0.2, s))
        if not chapters or chapters[-1][1] != chapter:
            chapters.append((tm["start"], chapter))
    with open(os.path.join(OUT, "R4F-guide.en.srt"), "w") as f:
        for k, (a, b, s) in enumerate(srt, 1):
            f.write(f"{k}\n{ts(a)} --> {ts(b)}\n{sub_lines(s)}\n\n")

    thumbnail().save(os.path.join(OUT, "R4F-thumbnail.png"))

    total = TIM[-1]["start"] + TIM[-1]["dur"]
    with open(os.path.join(OUT, "youtube.txt"), "w") as f:
        f.write("TITLE\nR4F: multichannel audio for macOS — R4F BUS and R4F BOX quick guide\n\n")
        f.write("DESCRIPTION\n")
        f.write("R4F is a free, open-source toolkit for macOS: two 256-channel virtual audio devices and a menu bar "
                "app.\n• R4F BUS: from your DAW (Ableton Live, Logic Pro, Reaper, Cubase, Pro Tools, Bitwig…) to one "
                "or more audio interfaces, with clock drift correction.\n• R4F BOX: audio from one app to another, "
                "with a routing matrix inside the driver.\n\n")
        f.write("Download and guide: https://github.com/Raf0404/R4F\n"
                "Installer: https://github.com/Raf0404/R4F/releases/latest\n\n")
        f.write("CHAPTERS\n")
        for a, name in chapters:
            f.write(f"{ts(a, srt=False)} {name}\n")
        f.write("\nTAGS\nR4F, macOS, multichannel audio, virtual audio device, CoreAudio, Ableton Live, Logic Pro, "
                "Reaper, audio routing, surround, 5.1, Ambisonics\n")
    print(f"ok: {final}  ({total:.0f} s)")


if __name__ == "__main__":
    main()
