"""Genera le suonerie HESH Originals come WAV 44.1 kHz mono 16 bit.
Pulse: due impulsi morbidi. Glass: accordo armonico con decadimento lungo.
Echo: nota che si ripete attenuandosi. SOS: tripletta insistente, piu' lunga.
"""
import math
import struct
import wave
from pathlib import Path

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "HESH" / "Resources" / "Sounds"
OUT.mkdir(parents=True, exist_ok=True)


def tone(freq, dur, amp=0.5, attack=0.01, decay=None, harmonics=(1.0,)):
    n = int(SR * dur)
    decay = decay or dur
    out = []
    for i in range(n):
        t = i / SR
        env = min(1.0, t / attack) * math.exp(-3 * t / decay)
        v = sum(h * math.sin(2 * math.pi * freq * (k + 1) * t) for k, h in enumerate(harmonics))
        out.append(amp * env * v / sum(harmonics))
    return out


def silence(dur):
    return [0.0] * int(SR * dur)


def mix(*parts):
    return [v for p in parts for v in p]


def write(name, samples):
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
    print(name, len(samples) / SR, "s")


write("pulse", mix(tone(880, 0.12, 0.6, decay=0.15), silence(0.08), tone(1175, 0.18, 0.6, decay=0.25)))
write("glass", mix(tone(1047, 1.4, 0.5, attack=0.005, decay=0.9, harmonics=(1.0, 0.5, 0.25, 0.12))))
write("echo", mix(tone(659, 0.2, 0.6, decay=0.3), silence(0.15), tone(659, 0.2, 0.35, decay=0.3), silence(0.15), tone(659, 0.2, 0.18, decay=0.3)))
sos = []
for _ in range(3):
    sos += mix(tone(1568, 0.14, 0.9, decay=0.2), silence(0.06), tone(1245, 0.14, 0.9, decay=0.2), silence(0.06), tone(1568, 0.22, 0.9, decay=0.3), silence(0.25))
write("sos", sos)
