#!/usr/bin/env python3
"""Voce neurale (Kokoro, onnx) per i video di R4F.

    build/tts/venv/bin/python video/tts.py jobs.json [voice] [speed]

jobs.json = [["testo", "percorso.wav"], ...]   (i file già presenti non vengono rigenerati)

Preparazione (una volta):
    python3 -m venv build/tts/venv && build/tts/venv/bin/pip install kokoro-onnx soundfile
    modello in build/tts/models: kokoro-v1.0.onnx e voices-v1.0.bin
    (https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0)
"""
import json
import os
import sys

import soundfile as sf
from kokoro_onnx import Kokoro

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "build", "tts", "models")


def main():
    jobs = [j for j in json.load(open(sys.argv[1])) if not os.path.exists(j[1])]
    voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
    speed = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    if not jobs:
        return
    k = Kokoro(os.path.join(MODELS, "kokoro-v1.0.onnx"), os.path.join(MODELS, "voices-v1.0.bin"))
    for text, path in jobs:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        samples, rate = k.create(text, voice=voice, speed=speed, lang="en-us")
        sf.write(path + ".tmp.wav", samples, rate, subtype="PCM_16")
        os.replace(path + ".tmp.wav", path)
        print(f"{len(samples) / rate:5.1f} s  {text[:70]}", flush=True)


if __name__ == "__main__":
    main()
