#!/usr/bin/env python3
"""Genera "R4F Out.amxd" (Max Audio Effect) senza aprire Max.

Formato .amxd: 'ampf' <u32 4> 'aaaa' 'meta' <u32 4> <u32 0> 'ptch' <u32 len> <JSON + "\\n\\0">.
Gli attributi degli oggetti UI ricalcano device esistenti (pattr blob come
M4L.api.SaveString di Ableton, live.tab, textedit, live.text in modalità pulsante).

    python3 device/build_device.py      → device/build/R4F Out.amxd
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "build")
W, H = 340.0, 169.0
FONT = "Arial Bold"

boxes, lines = [], []
_ids = iter(range(1, 1000))


def box(maxclass, rect, pres=None, **attrs):
    bid = "obj-%d" % next(_ids)
    b = {"id": bid, "maxclass": maxclass, "patching_rect": list(rect), "fontname": FONT, "fontsize": 10.0}
    if pres is not None:
        b["presentation"] = 1
        b["presentation_rect"] = list(pres)
    b.update(attrs)
    boxes.append({"box": b})
    return bid


def obj(text, rect, nin, nout, outtype=None, **attrs):
    return box("newobj", rect, text=text, numinlets=nin, numoutlets=nout,
               outlettype=outtype if outtype is not None else [""] * nout, **attrs)


def wire(src, so, dst, di):
    lines.append({"patchline": {"source": [src, so], "destination": [dst, di]}})


def comment(text, rect, pres=None, **attrs):
    return box("comment", rect, pres, text=text, numinlets=1, numoutlets=0, **attrs)


# --- audio: passa invariato -------------------------------------------------
pin = obj("plugin~", (20, 20, 53, 20), 2, 2, ["signal", "signal"])
pout = obj("plugout~", (20, 300, 53, 20), 2, 2, ["signal", "signal"])
wire(pin, 0, pout, 0)
wire(pin, 1, pout, 1)

# --- logica ------------------------------------------------------------------
dev = obj("live.thisdevice", (120, 20, 83, 22), 1, 3, ["bang", "int", "int"])
js = obj("js livebus_out.js", (120, 200, 160, 22), 1, 4,
         saved_object_attributes={"filename": "livebus_out.js", "parameter_enable": 0})
wire(dev, 0, js, 0)

udp = obj("udpsend 127.0.0.1 7400", (120, 260, 140, 22), 1, 0, [])
wire(js, 0, udp, 0)

# destinazioni salvate nel Set: pattr di tipo blob, solo memorizzato (non automatizzabile)
obj("pattr lbstate", (420, 20, 85, 22), 1, 3, varname="lbstate", restore=[0.0],
    saved_object_attributes={"parameter_enable": 1},
    saved_attribute_attributes={"valueof": {
        "parameter_longname": "lbstate", "parameter_shortname": "lbstate",
        "parameter_type": 3, "parameter_invisible": 1, "parameter_initial_enable": 0,
        "parameter_linknames": 0, "parameter_modmode": 0}})

# --- interfaccia -------------------------------------------------------------
comment("R4F Out", (300, 20, 100, 20), (6, 3, 120, 20), fontsize=12.0)

mode = box("live.tab", (300, 60, 100, 20), (6, 25, 96, 18),
           varname="mode", numinlets=1, numoutlets=3, outlettype=["", "", "float"],
           parameter_enable=1, num_lines_patching=1, num_lines_presentation=1, fontsize=9.0,
           saved_attribute_attributes={"valueof": {
               "parameter_enum": ["Stereo", "Mono"], "parameter_longname": "Modo",
               "parameter_shortname": "Modo", "parameter_type": 2, "parameter_mmax": 1,
               "parameter_initial": [0.0], "parameter_initial_enable": 1,
               "parameter_linknames": 1, "parameter_modmode": 0, "parameter_unitstyle": 9}})
pmode = obj("prepend mode", (300, 90, 80, 22), 1, 1)
wire(mode, 0, pmode, 0)
wire(pmode, 0, js, 0)

btn = box("live.text", (420, 60, 80, 20), (108, 25, 70, 18),
          text="Riassegna", mode=0, numinlets=1, numoutlets=2, outlettype=["", ""],
          parameter_enable=0, fontsize=9.0)
reassign = box("message", (420, 90, 60, 22), text="reassign", numinlets=2, numoutlets=1, outlettype=[""])
wire(btn, 0, reassign, 0)
wire(reassign, 0, js, 0)

comment("destinazioni  (es.  a:1-2  b:5@-6)", (300, 130, 200, 20), (6, 47, 300, 18), fontsize=9.0)
te = box("textedit", (300, 150, 220, 22), (6, 64, W - 12, 22),
         varname="dest", numinlets=1, numoutlets=3, outlettype=["", "int", ""],
         outputmode=1, keymode=1, lines=1, fontsize=11.0)
ptext = obj("prepend text", (300, 180, 80, 22), 1, 1)
wire(te, 0, ptext, 0)
wire(ptext, 0, js, 0)
wire(js, 1, te, 0)

st1 = comment("in attesa di Live", (300, 240, 320, 20), (6, 92, W - 12, 18))
st2 = comment("", (300, 262, 320, 20), (6, 112, W - 12, 18), fontsize=9.0)
wire(js, 2, st1, 0)
wire(js, 3, st2, 0)
comment("id uscite = config di livebus   ·   @dB = guadagno   ·   Riassegna = nuovo canale del bus",
        (300, 290, 420, 20), (6, 140, W - 12, 18), fontsize=8.0, textcolor=[0.6, 0.6, 0.6, 1.0])

# --- patcher -----------------------------------------------------------------
params = {}
for b in boxes:
    bx = b["box"]
    if bx.get("maxclass") == "live.tab":
        params[bx["id"]] = ["Modo", "Modo", 0]
    if bx.get("text", "").startswith("pattr "):
        params[bx["id"]] = ["lbstate", "lbstate", 0]
params["parameterbanks"] = {"0": {"index": 0, "name": "", "parameters": ["-"] * 8}}
params["inherited_shortname"] = 1

patcher = {
    "patcher": {
        "fileversion": 1,
        "appversion": {"major": 9, "minor": 0, "revision": 8, "architecture": "x64", "modernui": 1},
        "classnamespace": "box",
        "rect": [100.0, 100.0, 760.0, 420.0],
        "openrect": [0.0, 0.0, W, H],
        "openinpresentation": 1,
        "devicewidth": W,
        "default_fontsize": 10.0,
        "default_fontname": FONT,
        "gridsize": [8.0, 8.0],
        "boxanimatetime": 500,
        "boxes": boxes,
        "lines": lines,
        "parameters": params,
        "dependency_cache": [{"name": "livebus_out.js", "patcherrelativepath": ".", "type": "TEXT", "implicit": 1}],
        "latency": 0,
        "is_mpe": 0,
        "external_mpe_tuning_enabled": 0,
        "minimum_live_version": "",
        "minimum_max_version": "",
        "platform_compatibility": 0,
        "project": {
            "version": 1, "creationdate": 3590052493, "modificationdate": 3590052493,
            "viewrect": [0.0, 0.0, 300.0, 500.0], "autoorganize": 1, "hideprojectwindow": 1,
            "showdependencies": 1, "autolocalize": 0, "contents": {"patchers": {}}, "layout": {},
            "searchpath": {}, "detailsvisible": 0, "amxdtype": 1633771873, "readonly": 0,
            "devpathtype": 0, "devpath": ".", "sortmode": 0, "viewmode": 0, "includepackages": 0,
        },
        "autosave": 0,
        "saved_attribute_attributes": {"default_plcolor": {"expression": ""}},
    }
}


def validate():
    ids = {b["box"]["id"]: b["box"] for b in boxes}
    for l in lines:
        s, so = l["patchline"]["source"]
        d, di = l["patchline"]["destination"]
        assert s in ids and d in ids, (s, d)
        assert so < ids[s]["numoutlets"], ("outlet", s, so)
        assert di < ids[d]["numinlets"], ("inlet", d, di)
    for b in ids.values():
        if "presentation_rect" in b:
            x, y, w, h = b["presentation_rect"]
            assert x >= 0 and y >= 0 and x + w <= W + 0.5 and y + h <= H + 0.5, ("fuori dal device", b["id"], b.get("text"))


def main():
    validate()
    body = json.dumps(patcher, indent="\t").encode("utf-8") + b"\n\x00"
    data = b"ampf" + struct.pack("<I", 4) + b"aaaa" + b"meta" + struct.pack("<I", 4) + struct.pack("<I", 0)
    data += b"ptch" + struct.pack("<I", len(body)) + body
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "R4F Out.amxd")
    with open(out, "wb") as f:
        f.write(data)
    print("ok:", out, "(%d box, %d cavi)" % (len(boxes), len(lines)))


if __name__ == "__main__":
    sys.exit(main())
