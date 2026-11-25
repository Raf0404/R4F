#!/usr/bin/env python3
"""Video illustrativo di R4F (R4F BUS e R4F BOX) per YouTube.

Copione › immagini 1920×1080 (Pillow) › voce italiana (say, voce Alice) › clip con leggero zoom e
dissolvenze (ffmpeg) › video unico, sottotitoli .srt, miniatura e testi per YouTube.

    python3 video/make_video.py            › build/video/R4F-guida.mp4 (+ .srt, miniatura, youtube.txt)
    python3 video/make_video.py --frames   › solo le immagini delle scene (per controllarle)

Richiede: ffmpeg, Pillow, macOS (say). Usa gli screenshot in docs/screenshots e gli schemi in docs/.
"""
import os
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "video")
FR = os.path.join(OUT, "frames")
AU = os.path.join(OUT, "audio")
CL = os.path.join(OUT, "clips")
SHOTS = os.path.join(ROOT, "docs", "screenshots")

W, H, FPS = 1920, 1080, 30
VOICE, RATE = "Alice", 178
BG = (31, 30, 29)
CARD = (46, 45, 43)
CARD2 = (60, 58, 55)
CYAN = (33, 196, 230)
WHITE = (255, 255, 255)
GREY = (160, 164, 170)
DARK = (16, 33, 42)

# ------------------------------------------------------------------ font

_FONTS = {}


def font(size, weight="Regular"):
    key = (size, weight)
    if key not in _FONTS:
        path = "/System/Library/Fonts/HelveticaNeue.ttc"
        chosen = None
        for i in range(16):
            try:
                f = ImageFont.truetype(path, size, index=i)
            except OSError:
                break
            if f.getname()[1] == weight:
                chosen = f
                break
        _FONTS[key] = chosen or ImageFont.truetype(path, size, index=0)
    return _FONTS[key]


def mono(size):
    return ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size, index=0)


# ------------------------------------------------------------------ elementi grafici

LOGO = Image.open(os.path.join(ROOT, "assets", "R4F-icon-1024.png")).convert("RGBA")


def canvas():
    img = Image.new("RGB", (W, H), BG)
    return img, ImageDraw.Draw(img)


def header(img, d, section):
    """Piccolo logo e nome della sezione in alto a sinistra."""
    lg = LOGO.resize((64, 64), Image.LANCZOS)
    img.paste(lg, (70, 44), lg)
    d.text((150, 60), section, font=font(30, "Medium"), fill=GREY)


def wrap(d, text, fnt, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=fnt) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def title_frame(title, subtitle, small=""):
    img, d = canvas()
    lg = LOGO.resize((360, 360), Image.LANCZOS)
    img.paste(lg, ((W - 360) // 2, 150), lg)
    tw = d.textlength(title, font=font(84, "Bold"))
    d.text(((W - tw) / 2, 560), title, font=font(84, "Bold"), fill=WHITE)
    sw = d.textlength(subtitle, font=font(40))
    d.text(((W - sw) / 2, 680), subtitle, font=font(40), fill=GREY)
    if small:
        mw = d.textlength(small, font=font(34, "Medium"))
        d.text(((W - mw) / 2, 780), small, font=font(34, "Medium"), fill=CYAN)
    return img


def card_frame(section, title, items, note=""):
    """Titolo grande e una lista di voci (testo, sottotesto)."""
    img, d = canvas()
    header(img, d, section)
    d.text((120, 170), title, font=font(64, "Bold"), fill=WHITE)
    y = 300
    for i, (head, sub) in enumerate(items):
        d.rounded_rectangle((120, y, W - 120, y + (130 if sub else 92)), 22, fill=CARD)
        d.ellipse((150, y + 28, 186, y + 64), fill=CYAN)
        n = str(i + 1)
        nw = d.textlength(n, font=font(26, "Bold"))
        d.text((168 - nw / 2, y + 31), n, font=font(26, "Bold"), fill=DARK)
        d.text((215, y + 24), head, font=font(40, "Medium"), fill=WHITE)
        if sub:
            d.text((215, y + 78), sub, font=font(30), fill=GREY)
        y += (130 if sub else 92) + 22
    if note:
        for j, line in enumerate(wrap(d, note, font(30), W - 240)):
            d.text((120, y + 10 + j * 40), line, font=font(30), fill=CYAN)
    return img


def two_cards(section, title, left, right):
    img, d = canvas()
    header(img, d, section)
    d.text((120, 170), title, font=font(64, "Bold"), fill=WHITE)
    for k, (name, lines, color) in enumerate([left, right]):
        x0 = 120 + k * 860
        d.rounded_rectangle((x0, 300, x0 + 820, 900), 28, fill=CARD, outline=color, width=4)
        d.text((x0 + 50, 340), name, font=font(58, "Bold"), fill=color)
        y = 450
        for line in lines:
            for j, l in enumerate(wrap(d, line, font(36), 720)):
                d.text((x0 + 50, y), l, font=font(36), fill=WHITE)
                y += 48
            y += 22
    return img


def table_frame(section, title, rows, note=""):
    img, d = canvas()
    header(img, d, section)
    d.text((120, 170), title, font=font(64, "Bold"), fill=WHITE)
    y = 300
    for i, (a, b) in enumerate(rows):
        d.rounded_rectangle((120, y, W - 120, y + 96), 18, fill=CARD if i % 2 == 0 else CARD2)
        d.text((160, y + 26), a, font=font(40, "Bold"), fill=CYAN)
        d.text((760, y + 28), b, font=font(38), fill=WHITE)
        y += 110
    if note:
        d.text((120, y + 20), note, font=font(32), fill=GREY)
    return img


def shot_frame(section, title, shot, crop, highlights=(), caption=""):
    """Screenshot ritagliato, centrato; le zone evidenziate restano accese, il resto si scurisce."""
    img, d = canvas()
    header(img, d, section)
    d.text((120, 150), title, font=font(54, "Bold"), fill=WHITE)
    src = Image.open(os.path.join(SHOTS, shot)).convert("RGB").crop(crop)
    area_w, area_h = W - 200, H - 260 - (70 if caption else 0)
    s = min(area_w / src.width, area_h / src.height)
    sw, sh = int(src.width * s), int(src.height * s)
    shown = src.resize((sw, sh), Image.LANCZOS)
    x0, y0 = (W - sw) // 2, 245
    if highlights:
        dim = Image.new("RGB", shown.size, (0, 0, 0))
        dark = Image.blend(shown, dim, 0.55)
        for (hx0, hy0, hx1, hy1) in highlights:
            box = (int((hx0 - crop[0]) * s), int((hy0 - crop[1]) * s), int((hx1 - crop[0]) * s), int((hy1 - crop[1]) * s))
            dark.paste(shown.crop(box), box[:2])
        shown = dark
    frame = Image.new("RGB", (sw + 16, sh + 16), CARD2)
    frame.paste(shown, (8, 8))
    img.paste(frame, (x0 - 8, y0 - 8))
    for (hx0, hy0, hx1, hy1) in highlights:
        box = (x0 + (hx0 - crop[0]) * s - 6, y0 + (hy0 - crop[1]) * s - 6, x0 + (hx1 - crop[0]) * s + 6, y0 + (hy1 - crop[1]) * s + 6)
        d.rounded_rectangle(box, 14, outline=CYAN, width=6)
    if caption:
        cw = d.textlength(caption, font=font(36, "Medium"))
        d.text(((W - cw) / 2, H - 105), caption, font=font(36, "Medium"), fill=CYAN)
    return img


def picture_frame(section, path, scale_to=1680):
    img, d = canvas()
    header(img, d, section)
    p = Image.open(path).convert("RGBA")
    s = scale_to / p.width
    p = p.resize((int(p.width * s), int(p.height * s)), Image.LANCZOS)
    img.paste(p, ((W - p.width) // 2, (H - p.height) // 2 + 40), p)
    return img


def menu_frame():
    """Illustrazione del menu di R4F nella barra dei menu (voci reali dell'app)."""
    img, d = canvas()
    header(img, d, "L'app R4F")
    d.text((120, 170), "Il menu di R4F", font=font(64, "Bold"), fill=WHITE)
    d.rectangle((0, 290, W, 330), fill=(58, 57, 55))
    lg = LOGO.resize((28, 28), Image.LANCZOS)
    img.paste(lg, (1190, 296), lg)
    x0, y0, w = 900, 340, 760
    items = [
        ("R4F BUS in esecuzione", "info"), ("bus: R4F BUS (256 canali)", "info"),
        ("  mac: Altoparlanti MacBook Pro — 2 can, ok, 22 ms", "info"), ("R4F BOX: 1:1 su 256 canali", "info"),
        ("-", ""), ("Ferma", "item"), ("Riavvia", "item"), ("-", ""),
        ("Configura R4F BUS…", "sel"), ("Configura R4F BOX…", "item"), ("Dispositivi audio", "item"),
        ("Mostra il log", "item"), ("-", ""), ("Avvia all'accesso", "item"), ("Esci da R4F", "item"),
    ]
    h = sum(14 if t == "-" else 44 for t, _ in items) + 24
    d.rounded_rectangle((x0, y0, x0 + w, y0 + h), 16, fill=(236, 235, 233))
    y = y0 + 12
    for text, kind in items:
        if text == "-":
            d.line((x0 + 18, y + 7, x0 + w - 18, y + 7), fill=(200, 199, 197), width=2)
            y += 14
            continue
        if kind == "sel":
            d.rounded_rectangle((x0 + 8, y, x0 + w - 8, y + 42), 8, fill=(64, 140, 240))
        col = (140, 140, 140) if kind == "info" else (WHITE if kind == "sel" else (25, 25, 25))
        d.text((x0 + 26, y + 7), text, font=font(28), fill=col)
        y += 44
    d.text((120, 380), "In alto a destra,", font=font(40), fill=GREY)
    d.text((120, 430), "nella barra dei menu.", font=font(40), fill=GREY)
    d.text((120, 540), "Stato, uscite,", font=font(40), fill=WHITE)
    d.text((120, 590), "e le due configurazioni:", font=font(40), fill=WHITE)
    d.text((120, 660), "R4F BUS e R4F BOX.", font=font(40, "Bold"), fill=CYAN)
    return img


# ------------------------------------------------------------------ copione
# (capitolo, testo letto, immagine). Il testo letto è scritto come si pronuncia.

def svg_png(name):
    """Converte uno schema SVG in PNG ad alta risoluzione con AppKit (NSImage legge l'SVG)."""
    src = os.path.join(ROOT, "docs", name)
    dst = os.path.join(OUT, name.replace(".svg", ".png"))
    tool = os.path.join(OUT, "svg2png")
    if not os.path.exists(tool):
        code = os.path.join(OUT, "svg2png.swift")
        open(code, "w").write("""import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let s = 2.0, w = Int(img.size.width * s), h = Int(img.size.height * s)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
""")
        subprocess.run(["swiftc", "-O", code, "-o", tool], check=True, capture_output=True)
    subprocess.run([tool, src, dst], check=True)
    return dst


def scenes():
    return [
        ("Introduzione",
         "Erre quattro effe: audio multicanale per macOS. In questo video vediamo come usare erre quattro effe bus "
         "ed erre quattro effe box.",
         lambda: title_frame("R4F", "Audio multicanale per macOS", "R4F BUS  ·  R4F BOX")),
        ("Introduzione",
         "Erre quattro effe installa due schede audio virtuali, da duecentocinquantasei canali ciascuna. "
         "Erre quattro effe bus porta le tracce del tuo programma musicale su una o più schede audio. "
         "Erre quattro effe box passa l'audio da un programma all'altro.",
         lambda: two_cards("Introduzione", "Due schede virtuali, un'app",
                           ("R4F BUS", ["Dalla DAW a una o più schede audio.", "256 canali, anche con clock diversi."], CYAN),
                           ("R4F BOX", ["Da un programma all'altro.", "Matrice dentro il driver, nessuna latenza in più."], WHITE))),
        ("Installazione",
         "Per installarla, scarica il pacchetto dalla pagina Releases su GitHub, chiudi il programma musicale e "
         "apri il file. Se macOS lo blocca, vai in Impostazioni di Sistema, Privacy e sicurezza, e premi: Apri comunque. "
         "Al primo avvio, consenti l'accesso al microfono: serve a erre quattro effe per leggere il bus.",
         lambda: card_frame("Installazione", "Installare R4F", [
             ("Scarica R4F-1.1.1.pkg", "github.com/Raf0404/R4F  ›  Releases"),
             ("Chiudi la DAW e apri il pacchetto", "Installa driver, app e device per Live"),
             ("Se macOS lo blocca: «Apri comunque»", "Impostazioni di Sistema › Privacy e sicurezza"),
             ("Consenti l'accesso al microfono", "Serve a R4F per leggere R4F BUS"),
         ])),
        ("Come funziona R4F BUS",
         "Ecco come funziona erre quattro effe bus. Il programma musicale suona su erre quattro effe bus, una traccia "
         "per canale. L'app erre quattro effe legge il bus e manda ogni canale alle schede che vuoi, correggendo la "
         "differenza tra i loro orologi.",
         lambda: picture_frame("R4F BUS", svg_png("schema-bus.svg"))),
        ("Come funziona R4F BUS",
         "Nel programma musicale scegli erre quattro effe bus come uscita, poi manda ogni traccia a un canale. "
         "In Ableton Live si usa Audio To, Ext Out. In Logic, lo slot Output. In Reaper, il pulsante Route. "
         "I canali uno e due, di solito, sono l'uscita principale.",
         lambda: table_frame("R4F BUS", "Collega la DAW", [
             ("Ableton Live", "Audio To › Ext. Out › canale"),
             ("Logic Pro", "strip › Output › Output N"),
             ("Reaper", "pulsante Route › uscita hardware"),
             ("Cubase, Pro Tools, Bitwig", "uscite / bus sui canali di R4F BUS"),
         ], "Canali 1-2 = uscita principale (Main). Usa dal 3 in su per le tracce.")),
        ("L'editor di R4F BUS",
         "Erre quattro effe vive nella barra dei menu. Da qui vedi lo stato, e apri le configurazioni del bus e della box.",
         menu_frame),
        ("L'editor di R4F BUS",
         "Nell'editor, per prima cosa aggiungi le schede su cui suonare. Il nome breve, come mac o blackhole, "
         "si dà da solo in base al dispositivo.",
         lambda: shot_frame("R4F BUS · Editor", "Le uscite", "bus-elenco.png", (20, 405, 1300, 705),
                            caption="nome automatico dal dispositivo:  mac, blackhole, fireface…")),
        ("L'editor di R4F BUS",
         "Poi le rotte: quali canali del bus, verso quale uscita e quali canali. Ogni riga dice subito quanti "
         "collegamenti crea, oppure mostra l'errore in rosso.",
         lambda: shot_frame("R4F BUS · Editor", "Le rotte", "bus-elenco.png", (20, 885, 1880, 1198),
                            caption="l'esito di ogni riga, subito")),
        ("L'editor di R4F BUS",
         "Il modo somma manda ogni canale su tutte le uscite della rotta, abbassando ciascuno in proporzione: "
         "il livello non sale mai. Il modo uno a uno va in coppia, come per lo stereo. "
         "Poi premi Salva e applica, e il routing cambia subito.",
         lambda: shot_frame("R4F BUS · Editor", "Somma o 1:1", "bus-elenco.png", (20, 885, 1880, 1198), [(925, 890, 1180, 1195)],
                            "Somma: ogni canale su tutte le uscite, a 1/N  ·  1:1: in coppia")),
        ("Matrice, testo e preset",
         "La matrice mostra tutto a colpo d'occhio: clicca una casella per collegare, trascina per collegarne tante.",
         lambda: shot_frame("R4F BUS · Matrice", "La matrice", "bus-matrice.png", (20, 890, 1320, 1650))),
        ("Matrice, testo e preset",
         "Se preferisci scrivere, usa la vista testo: una rotta per riga. Freccia semplice per la somma, "
         "freccia doppia per l'uno a uno.",
         lambda: shot_frame("R4F BUS · Testo", "Il testo", "bus-testo.png", (20, 840, 1500, 1420),
                            caption="->  somma      =>  1:1      @-3  guadagno")),
        ("Matrice, testo e preset",
         "Con i preset crei in un attimo stereo, quadrifonia, cinque punto uno, sette punto uno e Ambisonics, "
         "scegliendo l'ordine dei canali nel programma e sugli altoparlanti.",
         lambda: shot_frame("R4F BUS · Preset", "I preset", "preset.png", (0, 0, 1120, 712))),
        ("R4F BOX",
         "Erre quattro effe box serve per passare l'audio tra programmi. Un programma suona sulle uscite della box, "
         "un altro registra dai suoi ingressi. Di base, ogni uscita arriva sul suo ingresso.",
         lambda: picture_frame("R4F BOX", svg_png("schema-box.svg"))),
        ("R4F BOX",
         "Da Configura erre quattro effe box puoi spostare, sommare o silenziare i canali. La matrice lavora dentro "
         "il driver: nessuna latenza in più, e funziona anche con l'app chiusa.",
         lambda: shot_frame("R4F BOX · Matrice", "La matrice della BOX", "box-matrice.png", (20, 580, 1320, 1240))),
        ("Ableton Live",
         "Se usi Ableton Live c'è anche il device erre quattro effe Out. Mettilo su una traccia e scrivi le "
         "destinazioni: sceglie da solo un canale libero, imposta l'uscita della traccia e salva tutto nel Set.",
         lambda: card_frame("Ableton Live", "Il device R4F Out", [
             ("Trascinalo su una traccia", "User Library › Max Audio Effect › R4F"),
             ("Scrivi le destinazioni", "es.  mac:1-2   oppure   fireface:3-4 blackhole:1@-6"),
             ("Fa il resto da solo", "canale libero del bus, Audio To, salvato nel Set"),
         ])),
        ("Dove trovarla",
         "Erre quattro effe è gratuita e open source. Trovi l'installer e la guida completa su github punto com, "
         "barra, Raf zero quattro zero quattro, barra, erre quattro effe.",
         lambda: title_frame("R4F", "github.com/Raf0404/R4F", "Installer e guida completa · GPL-3.0")),
    ]


# ------------------------------------------------------------------ produzione

def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def ts(t, srt=True):
    h, m, s = int(t // 3600), int(t % 3600 // 60), t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",") if srt else f"{m}:{int(s):02d}"


def display_text(spoken):
    """Testo per i sottotitoli: come si legge sullo schermo, non come si pronuncia."""
    t = spoken
    for a, b in [("erre quattro effe", "R4F"), ("Erre quattro effe", "R4F"), ("duecentocinquantasei", "256"),
                 ("cinque punto uno", "5.1"), ("sette punto uno", "7.1"), ("uno a uno", "1:1"),
                 ("github punto com, barra, Raf zero quattro zero quattro, barra, R4F", "github.com/Raf0404/R4F"),
                 (" bus", " BUS"), (" box", " BOX"), ("Ext Out", "Ext. Out")]:
        t = t.replace(a, b)
    return t


def main():
    only_frames = "--frames" in sys.argv
    for p in (OUT, FR, AU, CL):
        os.makedirs(p, exist_ok=True)
    sc = scenes()
    clips, srt, chapters, t = [], [], [], 0.0
    for i, (chapter, spoken, build) in enumerate(sc):
        frame = os.path.join(FR, f"{i:02d}.png")
        build().save(frame)
        if only_frames:
            continue
        voice = os.path.join(AU, f"{i:02d}.aiff")
        run(["say", "-v", VOICE, "-r", str(RATE), "-o", voice, spoken])
        lead, tail = 0.5, 0.9
        dur = lead + duration(voice) + tail
        n = int(round(dur * FPS))
        clip = os.path.join(CL, f"{i:02d}.mp4")
        vf = (f"[0:v]scale=3840:2160,zoompan=z='1+0.03*on/{n}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
              f":d={n}:s={W}x{H}:fps={FPS},fade=t=in:st=0:d=0.35,fade=t=out:st={dur - 0.35:.3f}:d=0.35,format=yuv420p[v];"
              f"[1:a]aresample=48000,adelay={int(lead * 1000)}:all=1,apad,atrim=0:{dur:.3f}[a]")
        run(["ffmpeg", "-y", "-i", frame, "-i", voice, "-filter_complex", vf, "-map", "[v]", "-map", "[a]",
             "-t", f"{dur:.3f}", "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "18",
             "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", clip])
        clips.append(clip)
        # sottotitoli: frasi distribuite in proporzione alla lunghezza
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", display_text(spoken)) if s.strip()]
        voiced = duration(voice)
        total = sum(len(s) for s in sentences)
        st = t + lead
        for s in sentences:
            d = voiced * len(s) / total
            srt.append((st, st + d, s))
            st += d
        if not chapters or chapters[-1][1] != chapter:
            chapters.append((t, chapter))
        t += dur
        print(f"scena {i + 1:2d}/{len(sc)}  {dur:5.1f} s  {chapter}")
    if only_frames:
        print("immagini in", FR)
        return

    lst = os.path.join(OUT, "clips.txt")
    open(lst, "w").write("".join(f"file '{c}'\n" for c in clips))
    final = os.path.join(OUT, "R4F-guida.mp4")
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", "-movflags", "+faststart", final])

    with open(os.path.join(OUT, "R4F-guida.srt"), "w") as f:
        for k, (a, b, s) in enumerate(srt, 1):
            f.write(f"{k}\n{ts(a)} --> {ts(b)}\n{s}\n\n")

    thumb = title_frame("R4F", "R4F BUS e R4F BOX: guida rapida", "Audio multicanale per macOS")
    thumb.resize((1280, 720), Image.LANCZOS).save(os.path.join(OUT, "R4F-miniatura.png"))

    with open(os.path.join(OUT, "youtube.txt"), "w") as f:
        f.write("TITOLO\nR4F: audio multicanale per macOS — guida a R4F BUS e R4F BOX\n\n")
        f.write("DESCRIZIONE\n")
        f.write("R4F è un toolkit gratuito e open source per macOS: due schede audio virtuali da 256 canali e un'app "
                "nella barra dei menu.\n• R4F BUS: dalla DAW (Ableton Live, Logic Pro, Reaper, Cubase, Pro Tools, "
                "Bitwig…) a una o più schede audio, con correzione della deriva dei clock.\n• R4F BOX: audio da un "
                "programma all'altro, con una matrice dentro il driver.\n\n")
        f.write("Download e guida: https://github.com/Raf0404/R4F\nInstaller: https://github.com/Raf0404/R4F/releases/latest\n\n")
        f.write("CAPITOLI\n")
        for a, name in chapters:
            f.write(f"{ts(a, srt=False)} {name}\n")
        f.write("\nTAG\nR4F, macOS, audio multicanale, scheda audio virtuale, CoreAudio, Ableton Live, Logic Pro, "
                "Reaper, routing audio, surround, 5.1, Ambisonics\n")
    print(f"ok: {final}  ({t:.0f} s)")


if __name__ == "__main__":
    main()
