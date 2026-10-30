"""Synthesizes assets/sounds/cha_ching.wav: a classic cash register
"cha-ching". First the lever's ratchet ("cha") and the drawer's thump,
then one loud bell strike that rings on ("ching") and the coins.

Made entirely from code here -- no recording or sample library -- so the
sound is the project's own and free to use commercially. No voice.
Peak level -1 dBFS; the app plays it at a fixed, moderate player volume.

    python3 tool/make_cha_ching.py                 # the app's sound
    python3 tool/make_cha_ching.py bright out.wav  # another style, to try
"""
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 44100
STYLES = ('classic', 'bright', 'coins')


def make(style):
    rng = np.random.default_rng(11)  # fixed seed: the same file every run
    length = {'classic': 1.6, 'bright': 1.2, 'coins': 1.5}[style]
    out = np.zeros(int(RATE * length))

    def at(start, signal):
        i = int(start * RATE)
        n = min(len(signal), len(out) - i)
        out[i:i + n] += signal[:n]

    def band_noise(seconds, low, high):
        n = int(seconds * RATE)
        spectrum = np.fft.rfft(rng.standard_normal(n))
        freqs = np.fft.rfftfreq(n, 1 / RATE)
        spectrum[(freqs < low) | (freqs > high)] = 0
        s = np.fft.irfft(spectrum, n)
        return s / np.abs(s).max()

    def click(start, gain, low=1200, high=6000, decay=260):
        s = band_noise(0.02, low, high)
        at(start, gain * s * np.exp(-np.arange(len(s)) / RATE * decay))

    def thump(start, gain):
        # The drawer hitting its stop: a short low knock.
        tt = np.arange(int(0.09 * RATE)) / RATE
        s = np.sin(2 * np.pi * 140 * tt) * np.exp(-tt * 45) + 0.4 * band_noise(len(tt) / RATE, 150, 900) * np.exp(-tt * 70)
        at(start, gain * s)

    def bell(f0, seconds, gain, decay=2.2):
        # A struck bell: inharmonic partials, each a close pair that beats
        # (the shimmer of a real bell), the high ones dying first.
        tt = np.arange(int(seconds * RATE)) / RATE
        s = np.zeros_like(tt)
        for ratio, amp, d in ((1.0, 1.0, 1.0), (2.0, 0.6, 1.5), (2.76, 0.5, 2.0),
                              (4.07, 0.3, 2.8), (5.40, 0.2, 3.6), (6.8, 0.1, 4.5)):
            f = f0 * ratio
            if f > 9500:
                continue
            for detune in (-2.5, 2.5):
                s += amp * 0.5 * np.sin(2 * np.pi * (f + detune * ratio) * tt + rng.uniform(0, 6.28)) * np.exp(-tt * decay * d)
        strike = band_noise(seconds, 3000, 8000) * np.exp(-tt * 400) * 0.6
        return gain * (s + strike) * np.minimum(1, tt / 0.0015)

    def coins(start, count, spread, gain):
        for _ in range(count):
            at(start + rng.uniform(0, spread), bell(rng.uniform(3000, 5200), 0.22, gain * rng.uniform(0.5, 1), decay=9))

    if style == 'classic':
        # "Cha": the lever's ratchet, a run of quick clicks, then the drawer.
        for k in range(5):
            click(0.012 * k * 3, 0.55 + 0.1 * k)
        thump(0.20, 0.9)
        # "Ching": one loud strike that rings on.
        at(0.20, bell(2350.0, 1.4, 1.0))
        coins(0.32, 6, 0.35, 0.10)
    elif style == 'bright':
        click(0.0, 0.8)
        click(0.05, 0.6)
        at(0.10, bell(3136.0, 1.1, 0.9, decay=3.0))
        at(0.17, bell(3951.0, 1.0, 0.6, decay=3.4))
        coins(0.28, 4, 0.25, 0.08)
    else:
        click(0.0, 0.7)
        thump(0.06, 0.7)
        at(0.08, bell(2637.0, 1.4, 0.9))
        coins(0.15, 18, 0.7, 0.16)

    # Firm and loud without clipping: a gentle limiter, then -1 dBFS.
    out /= np.abs(out).max()
    out = np.tanh(2.2 * out) / np.tanh(2.2)
    fade = int(0.2 * RATE)
    out[-fade:] *= np.linspace(1, 0, fade)
    return out * (10 ** (-1 / 20)) / np.abs(out).max()


def write(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((samples * 32767).astype('<i2').tobytes())
    print(path, path.stat().st_size, 'bytes')


if __name__ == '__main__':
    style = sys.argv[1] if len(sys.argv) > 1 else 'classic'
    assert style in STYLES, STYLES
    default = Path(__file__).resolve().parent.parent / 'assets' / 'sounds' / 'cha_ching.wav'
    write(Path(sys.argv[2]) if len(sys.argv) > 2 else default, make(style))
