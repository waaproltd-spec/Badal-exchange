"""Synthesizes assets/sounds/cha_ching.wav: a cash register "cha-ching"
(a short mechanical rattle, then two bright bell strikes and a coin shimmer).

Made entirely from code here -- no recording or sample library -- so the
sound is the project's own and free to use commercially. No voice.
Peak level -1 dBFS; the app plays it at a fixed, moderate player volume.

    python3 tool/make_cha_ching.py
"""
import wave
from pathlib import Path

import numpy as np

RATE = 44100
LENGTH = 1.25  # seconds
rng = np.random.default_rng(7)  # fixed seed: the same file every run
t = np.arange(int(RATE * LENGTH)) / RATE
out = np.zeros_like(t)


def at(start, signal):
    i = int(start * RATE)
    n = min(len(signal), len(out) - i)
    out[i:i + n] += signal[:n]


def band_noise(seconds, low, high):
    n = int(seconds * RATE)
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spectrum[(freqs < low) | (freqs > high)] = 0
    return np.fft.irfft(spectrum, n)


# "Cha": the drawer lever -- two clicks and a short metallic rattle.
for start, gain in ((0.000, 0.9), (0.045, 0.6)):
    s = band_noise(0.025, 1500, 7000)
    at(start, gain * s / np.abs(s).max() * np.exp(-np.arange(len(s)) / RATE * 180))
rattle = band_noise(0.11, 2500, 6500)
at(0.02, 0.35 * rattle / np.abs(rattle).max() * np.exp(-np.arange(len(rattle)) / RATE * 30))


def bell(f0, seconds, gain):
    # A small bell's inharmonic partials, the high ones dying first.
    tt = np.arange(int(seconds * RATE)) / RATE
    s = np.zeros_like(tt)
    for ratio, amp, decay in ((1.0, 1.0, 3.2), (2.0, 0.55, 4.5), (2.76, 0.45, 6.0),
                              (4.07, 0.25, 8.0), (5.40, 0.15, 11.0)):
        f = f0 * ratio
        if f < 9000:
            s += amp * np.sin(2 * np.pi * f * tt + rng.uniform(0, 6.28)) * np.exp(-tt * decay)
    attack = np.minimum(1, tt / 0.002)
    return gain * s * attack


# "Ching": two strikes, close together, slightly detuned.
at(0.13, bell(2093.0, 1.1, 0.75))
at(0.19, bell(2637.0, 1.0, 0.55))

# Coins settling: a few short high tinkles.
for start in (0.30, 0.37, 0.46, 0.55):
    at(start, bell(rng.uniform(3200, 4200), 0.25, 0.12))

# Fade out the tail, then normalize to -1 dBFS.
fade = int(0.15 * RATE)
out[-fade:] *= np.linspace(1, 0, fade)
out *= (10 ** (-1 / 20)) / np.abs(out).max()

path = Path(__file__).resolve().parent.parent / 'assets' / 'sounds' / 'cha_ching.wav'
path.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(path), 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes((out * 32767).astype('<i2').tobytes())
print(path, path.stat().st_size, 'bytes')
