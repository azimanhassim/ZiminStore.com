"""Original instrumental for ZiminStore ("Study Night", lo-fi, 72 BPM, A minor).
Fully synthesised from sine waves and noise: no samples, no third-party material.
Renders a seamless loop to WAV (mono, 44.1 kHz)."""
import numpy as np, wave, sys

SR = 44100
BPM = 72
BEAT = 60 / BPM
BAR = 4 * BEAT
BARS = 16
L = int(round(BARS * BAR * SR))
TAIL = int(3.0 * SR)
rng = np.random.default_rng(20261114)

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)

def env(n, a, d):
    t = np.arange(n) / SR
    e = np.exp(-t / d)
    na = max(1, int(a * SR))
    e[:na] *= np.linspace(0, 1, na)
    return e

def add(buf, start_s, sig):
    i = int(start_s * SR)
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i]

def epiano(m, dur, vel):
    n = int((dur + 1.5) * SR); t = np.arange(n) / SR; f = hz(m)
    trem = 1 + 0.04 * np.sin(2 * np.pi * 4.2 * t)
    s = (np.sin(2*np.pi*f*t) + 0.28*np.sin(2*np.pi*2*f*t)*np.exp(-t/0.35)
         + 0.08*np.sin(2*np.pi*3*f*t)*np.exp(-t/0.15))
    e = env(n, 0.006, 1.1)
    rel = int(dur * SR)
    if rel < n: e[rel:] *= np.exp(-np.arange(n - rel) / SR / 0.25)
    return vel * s * e * trem

def pad(ms, dur):
    n = int((dur + 0.8) * SR); t = np.arange(n) / SR; s = np.zeros(n)
    for m in ms:
        for det in (-0.07, 0.0, 0.06):
            f = hz(m + det)
            for k, a in ((1, 1.0), (2, 0.35), (3, 0.15), (4, 0.06)):
                s += a * np.sin(2*np.pi*f*k*t + rng.uniform(0, 6.28))
    na, nr = int(0.9*SR), int(0.8*SR)
    e = np.ones(n); e[:na] = np.linspace(0, 1, na) ** 2
    e[-nr:] *= np.linspace(1, 0, nr) ** 2
    return s * e / (len(ms) * 3)

def bass(m, dur):
    n = int((dur + 0.2) * SR); t = np.arange(n) / SR; f = hz(m)
    s = np.sin(2*np.pi*f*t) + 0.15*np.sin(2*np.pi*2*f*t)
    e = env(n, 0.01, 1.6); r = int(dur*SR)
    if r < n: e[r:] *= np.linspace(1, 0, n - r)
    return s * e

def kick():
    n = int(0.35 * SR); t = np.arange(n) / SR
    f = 48 + 70 * np.exp(-t / 0.03)
    return np.sin(2*np.pi*np.cumsum(f)/SR) * np.exp(-t/0.12)

def hat(vel):
    n = int(0.06 * SR); x = rng.standard_normal(n)
    x = np.diff(np.diff(x, prepend=0), prepend=0)
    return vel * x * np.exp(-np.arange(n)/SR/0.012) * 0.25

# Am9 - Fmaj9 - Cmaj7 - G6  (two bars each, twice)
CHORDS = [(45, [60, 64, 67, 71]), (41, [57, 60, 64, 67]),
          (48, [55, 59, 64, 67]), (43, [55, 59, 62, 64])]

dry = np.zeros(L + TAIL); send = np.zeros(L + TAIL); drums = np.zeros(L + TAIL)
for bar in range(BARS):
    root, voic = CHORDS[(bar // 2) % 4]
    t0 = bar * BAR
    if bar % 2 == 0:
        p = pad(voic, 2 * BAR); add(dry, t0, 0.22 * p); add(send, t0, 0.30 * p)
    add(dry, t0, 0.32 * bass(root, 2.5 * BEAT))
    add(dry, t0 + 2.5 * BEAT, 0.22 * bass(root + (7 if bar % 2 else 12), 1.4 * BEAT))
    # Rhodes chord stabs on beat 1 (and the "and" of 3 in second half)
    for i, m in enumerate(voic):
        add(send, t0 + i * 0.012, epiano(m, 1.6 * BEAT, 0.10))
    if bar >= 8:
        for i, m in enumerate(voic[1:]):
            add(send, t0 + 2.5 * BEAT + i * 0.01, epiano(m, 0.8 * BEAT, 0.06))
    # Arpeggio, sparser in the first half
    arp = [voic[k] + 12 for k in (0, 2, 1, 3, 2, 1, 3, 2)]
    for s8 in range(8):
        if bar < 8 and s8 % 2: continue
        if rng.random() < 0.18: continue
        add(send, t0 + s8 * BEAT / 2 + rng.uniform(0, 0.012),
            epiano(arp[s8], 0.45 * BEAT, 0.045 + 0.02 * rng.random()))
    # Soft lo-fi drums from bar 4
    if bar >= 4:
        add(drums, t0, 0.55 * kick()); add(drums, t0 + 2.5 * BEAT, 0.35 * kick())
        for s8 in range(8):
            add(drums, t0 + s8 * BEAT / 2 + (0.03 if s8 % 2 else 0), hat(0.9 if s8 % 2 else 0.55))

# Reverb: convolution with a synthetic decaying-noise impulse response
ir_n = int(2.4 * SR); ir = rng.standard_normal(ir_n) * np.exp(-np.arange(ir_n)/SR/0.55)
ir = np.convolve(ir, np.ones(8)/8, mode='same'); ir /= np.sqrt(np.sum(ir**2))
N = 1 << int(np.ceil(np.log2(len(send) + ir_n)))
wet = np.fft.irfft(np.fft.rfft(send, N) * np.fft.rfft(ir, N), N)[: len(send) + ir_n]

mix = np.zeros(len(wet)); mix[:len(dry)] += dry; mix[:len(send)] += 0.85 * send
mix[:len(drums)] += drums; mix += 0.28 * wet
# Seamless loop: fold everything past the loop point back onto the start
out = mix[:L].copy()
tail = mix[L:]
for k in range(0, len(tail), L):
    seg = tail[k:k + L]; out[:len(seg)] += seg
# Gentle vinyl-like noise bed and soft limiting
out += 0.0025 * np.convolve(rng.standard_normal(L), np.ones(30)/30, mode='same')
out = np.tanh(1.3 * out / np.max(np.abs(out))) / np.tanh(1.3) * 0.89

pcm = (out * 32767).astype('<i2')
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print(f"{L/SR:.1f}s, peak {np.max(np.abs(out)):.2f}, loop-seam jump {abs(out[0]-out[-1]):.4f}")
