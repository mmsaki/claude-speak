#!/usr/bin/env python3
"""Procedural sound-cue generator for claude-speak.

Dependency-free (stdlib only). Reproduces the synthesis design from Kit Langton's
visual-effect TaskSounds.ts: pentatonic notes, per-voice ADSR, oscillator variety
(sine / triangle / sawtooth / fatsaw / square4), light Schroeder reverb, and a
tanh waveshaper for the distorted "death" cue. Renders each cue to a 16-bit mono
WAV in the output directory.

Usage: python3 gen_sounds.py <out_dir>
"""
import math, struct, sys, wave, os

SR = 44100
BPM = 120
QUARTER = 60.0 / BPM            # seconds per quarter note (0.5s @ 120)

def dur(n):                      # Tone.js note value -> seconds ("4n", "32n", ...)
    return QUARTER * 4.0 / float(str(n).rstrip("n"))

def midi(note):                 # "C4", "D#3", "E6" -> MIDI number
    names = {"C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11}
    i = 1
    semi = names[note[0].upper()]
    if note[1] in "#b":
        semi += 1 if note[1] == "#" else -1
        i = 2
    octave = int(note[i:])
    return 12 * (octave + 1) + semi

def freq(note):
    return 440.0 * 2.0 ** ((midi(note) - 69) / 12.0)

# --- oscillators (return sample for phase t seconds at frequency f) ----------
def osc(kind, f, t):
    w = 2 * math.pi * f * t
    if kind == "sine":
        return math.sin(w)
    if kind == "triangle":
        return (2.0 / math.pi) * math.asin(math.sin(w))
    if kind == "sawtooth":
        x = f * t
        return 2.0 * (x - math.floor(x + 0.5))
    if kind == "square4":                     # band-limited square, 4 partials
        s = 0.0
        for k in range(1, 5):
            h = 2 * k - 1
            s += math.sin(w * h) / h
        return s * (4.0 / math.pi) * 0.4
    if kind == "fatsaw":                       # detuned saw stack
        cents = (-16, -10, -4, 0, 4, 10, 16)
        s = 0.0
        for c in cents:
            ff = f * (2.0 ** (c / 1200.0))
            x = ff * t
            s += 2.0 * (x - math.floor(x + 0.5))
        return s / len(cents)
    return math.sin(w)

def adsr(i, n, a, d, s, r):                    # sample index i, note length n samples
    a_s, d_s, r_s = a * SR, d * SR, r * SR
    if i < a_s:
        return i / a_s if a_s else 1.0
    if i < a_s + d_s:
        return 1.0 - (1.0 - s) * ((i - a_s) / d_s if d_s else 1.0)
    if i < n:
        return s
    rel = i - n
    if rel < r_s:
        return s * (1.0 - rel / r_s)
    return 0.0

# --- a "voice" = one note (or note-stack played together) --------------------
def voice(buf, off, kind, note, gain, durn, env, dist=False):
    a, d, s, r = env
    n_samp = int(dur(durn) * SR)
    total = n_samp + int(r * SR)
    start = int(off * SR)
    f = freq(note)
    for i in range(total):
        e = adsr(i, n_samp, a, d, s, r)
        if e <= 0:
            continue
        v = osc(kind, f, i / SR) * e * gain
        if dist:
            v = math.tanh(v * 3.0)
        j = start + i
        if j < len(buf):
            buf[j] += v

# --- light Schroeder reverb --------------------------------------------------
def reverb(buf, wet=0.2):
    out = list(buf)
    combs = [(1557, 0.77), (1617, 0.80), (1491, 0.75), (1422, 0.73)]
    acc = [0.0] * len(buf)
    for delay, fb in combs:
        cb = [0.0] * len(buf)
        for i in range(len(buf)):
            cb[i] = buf[i] + (fb * cb[i - delay] if i >= delay else 0.0)
        for i in range(len(buf)):
            acc[i] += cb[i] / len(combs)
    for delay, g in [(225, 0.7), (556, 0.7)]:
        ap = [0.0] * len(buf)
        for i in range(len(buf)):
            d = acc[i - delay] if i >= delay else 0.0
            ap[i] = -g * acc[i] + d + g * (ap[i - delay] if i >= delay else 0.0)
        acc = ap
    for i in range(len(buf)):
        out[i] = buf[i] * (1 - wet) + acc[i] * wet
    return out

# --- cue definitions (event, voices, reverb wet, distortion) -----------------
# voice tuple: (offset_s, osc, note, gain, note_value, (a,d,s,r))
CUES = {
    # only the cues actually wired to events (see scripts/event.sh)
    "send":     ([(0.0, "sine", "C5", 0.30, "32n", (0.002,0.06,0,0.06)),
                  (0.05,"sine", "G5", 0.30, "32n", (0.002,0.06,0,0.06))], 0.18, False),
    "tick":     ([(0.0, "sine", "G4", 0.25, "32n", (0.002,0.08,0,0.10))], 0.15, False),
    "failure":  ([(0.0, "sawtooth","D2",0.65,"4n",(0.02,0.4,0.1,0.8))], 0.25, False),
    "reset":    ([(0.0, "sine","G3",0.55,"16n",(0.004,0.18,0,0.12)),
                  (0.1, "sine","C3",0.55,"16n",(0.004,0.18,0,0.12))], 0.22, False),
    "running":  ([(0.0,"sine","E4",0.25,"32n",(0.002,0.08,0,0.1))], 0.2, False),
    "permission":([(0.0, "triangle","G5",0.6,"16n",(0.001,0.05,0,0.05)),
                  (0.16,"triangle","G5",0.6,"16n",(0.001,0.05,0,0.05))], 0.2, False),
}

def render(name, spec, out_dir):
    voices, wet, dist = spec
    length = max(int((off + dur(dn) + env[3] + 0.4) * SR) for off,_,_,_,dn,env in voices)
    buf = [0.0] * length
    for off, kind, note, gain, dn, env in voices:
        voice(buf, off, kind, note, gain, dn, env, dist=dist)
    if wet > 0:
        buf = reverb(buf, wet)
    peak = max((abs(x) for x in buf), default=1.0) or 1.0
    scale = 0.7 / peak
    path = os.path.join(out_dir, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, int(x * scale * 32767)))) for x in buf))
    return path

def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    for name, spec in CUES.items():
        render(name, spec, out_dir)
    open(os.path.join(out_dir, ".rendered"), "w").close()
    print(f"rendered {len(CUES)} cues -> {out_dir}")

if __name__ == "__main__":
    main()
