#!/usr/bin/env python3
"""Synthesizes Lunalert's cosmic notification sounds. Pure standard library, no samples.

Usage: python3 scripts/make-sounds.py [Lunalert/Resources/Sounds]

Each sound is rendered at 44.1 kHz mono, given a small shared "night air" reverb, normalized so its
peak sits at -3 dBFS, written as WAV and converted to 16-bit linear PCM .caf with macOS's afconvert.
The output is deterministic (fixed random seeds), so re-running only changes files you edited here.
"""
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 44_100
PEAK_DBFS = -3.0
TAU = 2 * math.pi


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def add(dst, src, at=0.0, gain=1.0):
    start = int(at * RATE)
    for i, v in enumerate(src):
        j = start + i
        if j >= len(dst):
            break
        dst[j] += v * gain
    return dst


def env_ad(n, attack, decay):
    """Soft (raised-cosine) attack, exponential decay with time constant `decay` seconds."""
    a = max(1, int(attack * RATE))
    out = []
    for i in range(n):
        t = i / RATE
        rise = 0.5 - 0.5 * math.cos(math.pi * i / a) if i < a else 1.0
        out.append(rise * math.exp(-max(0.0, t - attack) / decay))
    return out


def fade_tail(sig, seconds=0.08):
    """Raised-cosine fade over the last `seconds` so nothing ends in a click."""
    n = min(len(sig), int(seconds * RATE))
    for k in range(n):
        sig[len(sig) - n + k] *= 0.5 + 0.5 * math.cos(math.pi * k / n)
    return sig


def bell(freq, seconds, attack=0.006, decay=0.5, partials=((1.0, 1.0, 1.0),), detune=0.0):
    """Sum of (ratio, amplitude, decay-scale) partials; higher partials die faster, like glass."""
    n = int(seconds * RATE)
    out = [0.0] * n
    for ratio, amp, dscale in partials:
        f = freq * ratio
        e = env_ad(n, attack, decay * dscale)
        f2 = f * (1 + detune)
        for i in range(n):
            t = i / RATE
            s = math.sin(TAU * f * t)
            if detune:
                s = 0.5 * (s + math.sin(TAU * f2 * t))
            out[i] += amp * e[i] * s
    return fade_tail(out, min(0.1, seconds / 3))


def reverb(sig, mix=0.22, tail=0.6):
    """Tiny Schroeder reverb: four damped combs into two allpasses. Extends the signal by `tail`."""
    sig = sig + silence(tail)
    wet = [0.0] * len(sig)
    for delay_ms, fb in ((29.7, 0.78), (37.1, 0.76), (41.1, 0.74), (43.7, 0.72)):
        d = int(delay_ms / 1000 * RATE)
        buf = [0.0] * d
        lp = 0.0
        for i, x in enumerate(sig):
            y = buf[i % d]
            lp = 0.6 * y + 0.4 * lp  # damping: highs fade faster, like air
            buf[i % d] = x + lp * fb
            wet[i] += y * 0.25
    for delay_ms, g in ((5.0, 0.7), (1.7, 0.7)):
        d = int(delay_ms / 1000 * RATE)
        buf = [0.0] * d
        for i, x in enumerate(wet):
            b = buf[i % d]
            y = -g * x + b
            buf[i % d] = x + g * y
            wet[i] = y
    return [(1 - mix) * x + mix * w for x, w in zip(sig, wet)]


def normalize(sig, dbfs=PEAK_DBFS):
    peak = max(abs(v) for v in sig) or 1.0
    target = 10 ** (dbfs / 20)
    return [v * target / peak for v in sig]


# ---------------------------------------------------------------------------------------------
# The sounds

GLASS = ((1.0, 1.0, 1.0), (2.76, 0.32, 0.45), (5.40, 0.12, 0.25), (8.93, 0.05, 0.15))


def starlight():
    """A soft glassy chime: one high bell, then a quieter one a fifth above, like two stars blinking."""
    out = silence(1.3)
    add(out, bell(1318.5, 1.3, attack=0.004, decay=0.38, partials=GLASS), 0.0, 1.0)   # E6
    add(out, bell(1975.5, 1.15, attack=0.004, decay=0.30, partials=GLASS), 0.11, 0.55)  # B6
    return reverb(fade_tail(out), mix=0.28, tail=0.45)


def pulsar():
    """Two quick, rounded blips, the second a touch higher: a distant beacon pulsing twice."""
    def blip(freq):
        n = int(0.16 * RATE)
        out = []
        for i in range(n):
            t = i / RATE
            a = min(1.0, t / 0.006)
            e = a * math.exp(-t / 0.045)
            f = freq * (1 + 0.04 * math.exp(-t / 0.02))  # tiny downward chirp, reads as "radio"
            out.append(e * (math.sin(TAU * f * t) + 0.25 * math.sin(TAU * 2 * f * t)))
        return fade_tail(out, 0.05)
    out = silence(0.55)
    add(out, blip(1046.5), 0.0, 1.0)    # C6
    add(out, blip(1396.9), 0.17, 0.85)  # F6
    return reverb(fade_tail(out), mix=0.30, tail=0.35)


def comet():
    """An airy swoosh (sweeping band-passed noise) with a sparkling tail of tiny high pings."""
    rng = random.Random(7)
    dur = 1.0
    n = int(dur * RATE)
    out = [0.0] * n
    # Band-pass (RBJ biquad) noise whose centre sweeps 600 Hz -> 4 kHz -> 2 kHz.
    x1 = x2 = y1 = y2 = 0.0
    for i in range(n):
        t = i / RATE
        p = t / dur
        fc = 600 + 3400 * math.sin(math.pi * min(1.0, p * 1.15)) ** 1.5 + 1400 * p
        q = 1.6
        w0 = TAU * fc / RATE
        alpha = math.sin(w0) / (2 * q)
        b0, b2 = alpha, -alpha
        a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
        x = rng.uniform(-1, 1)
        y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x, y1, y
        swell = math.sin(math.pi / 2 * t / 0.55) ** 2 if t < 0.55 else math.exp(-(t - 0.55) / 0.12)
        out[i] = y * swell * 1.6
    out = fade_tail(out, 0.1) + silence(0.6)
    for k in range(9):  # sparkles
        at = 0.32 + k * 0.085 + rng.uniform(-0.02, 0.02)
        f = rng.choice((2637.0, 3135.9, 3520.0, 3951.1, 4186.0))
        add(out, bell(f, 0.35, attack=0.002, decay=0.07, partials=((1, 1, 1), (2.76, 0.2, 0.5))),
            at, 0.28 * (1 - k / 11))
    return reverb(fade_tail(out), mix=0.32, tail=0.4)


def orbit():
    """A low, round ping with a slow beat between two close tones, like something turning far away."""
    out = silence(1.6)
    partials = ((1.0, 1.0, 1.0), (2.0, 0.35, 0.6), (3.01, 0.10, 0.35))
    add(out, bell(392.0, 1.6, attack=0.012, decay=0.55, partials=partials, detune=0.0022), 0, 1.0)  # G4
    add(out, bell(784.0, 0.6, attack=0.004, decay=0.08, partials=GLASS), 0, 0.18)  # a small strike on top
    return reverb(fade_tail(out, 0.15), mix=0.25, tail=0.4)


def nebula():
    """A slow pad bloom: a soft, detuned open chord that swells in and dissolves."""
    dur = 1.7
    n = int(dur * RATE)
    out = [0.0] * n
    notes = (440.0, 659.3, 987.8, 1318.5)  # A4 E5 B5 E6: open fifths, no tension
    amps = (1.0, 0.7, 0.45, 0.22)
    for f, a in zip(notes, amps):
        for cents in (-6, 6):
            ff = f * 2 ** (cents / 1200)
            ph = random.Random(int(ff)).uniform(0, TAU)
            for i in range(n):
                out[i] += a * math.sin(TAU * ff * i / RATE + ph)
    for i in range(n):
        t = i / RATE
        swell = math.sin(math.pi / 2 * min(1.0, t / 0.45)) ** 2
        fall = math.exp(-max(0.0, t - 0.45) / 0.42)
        shimmer = 1 + 0.06 * math.sin(TAU * 5.2 * t)
        out[i] *= swell * fall * shimmer
    return reverb(fade_tail(out, 0.2), mix=0.30, tail=0.3)


def moonrise():
    """Three soft notes climbing (E5, A5, C#6): gentle, a little hopeful."""
    out = silence(1.4)
    soft = ((1.0, 1.0, 1.0), (2.0, 0.18, 0.5), (3.0, 0.06, 0.3))
    for k, f in enumerate((659.3, 880.0, 1108.7)):
        add(out, bell(f, 1.4 - k * 0.13, attack=0.015, decay=0.32 + 0.08 * k, partials=soft),
            k * 0.13, 0.75 + 0.1 * k)
    return reverb(fade_tail(out, 0.15), mix=0.28, tail=0.35)


SOUNDS = {
    "Starlight": starlight,
    "Pulsar": pulsar,
    "Comet": comet,
    "Orbit": orbit,
    "Nebula": nebula,
    "Moonrise": moonrise,
}


def write(name, sig, out_dir):
    sig = normalize(sig)
    frames = b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in sig)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(frames)
        caf = os.path.join(out_dir, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@44100", "-c", "1", wav, caf], check=True)
    peak = max(abs(v) for v in sig)
    print(f"{name:10s} {len(sig) / RATE:4.2f}s  peak {20 * math.log10(peak):5.1f} dBFS")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "Lunalert/Resources/Sounds"
    os.makedirs(out_dir, exist_ok=True)
    for name, make in SOUNDS.items():
        write(name, make(), out_dir)


if __name__ == "__main__":
    main()
