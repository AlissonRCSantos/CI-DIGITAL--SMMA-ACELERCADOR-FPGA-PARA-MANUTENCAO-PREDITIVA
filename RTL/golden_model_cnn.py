#!/usr/bin/env python3
"""Modelo de referencia (golden model) bit-exato da CNN em ponto fixo Q1.15.
Usado para gerar os valores esperados dos testbenches."""

W, FRAC = 16, 15
MAXV, MINV = (1 << (W - 1)) - 1, -(1 << (W - 1))

# ---- PESOS TREINADOS (gerados por python/scripts/05_exportar_rtl.py) ----
# Kernels: indice = filtro, lista de 9 taps em ordem linha*3+coluna
KER = [
    [-12872, -14111, -10184,  -2588,  -6374,   -736, -10528, -20151, -17247],  # F0,
    [ 14414,  15634,  10516,  27116,  32121,  26796,  -7308,   1373,  -3780],  # F1,
    [-20767,  11999, -16420, -12714,  15250,  -8552, -32760,   7063, -32760],  # F2,
    [ -5866,  -2507,  -8794, -17934, -13215, -15409,  -7523,  -6671,  -1537],  # F3,
    [-18437, -31713, -18748,   1822,   2225,   2484, -32767, -32765, -32767],  # F4,
    [   989,    171,  -1988, -23809, -25552, -22815,  -6071,  -1908,  -2096],  # F5,
    [-11103, -13398,  -4422,   -359,  -1265,    853, -16771, -16568, -17047],  # F6,
    [-32737, -32736, -32028, -15581,  -1232, -16887,  32767,  32766,  32766],  # F7,
]
BIAS = [-2269, -32766, 31392, 3040, 32752, -2544, -2132, -13305]

DENSE_W = [
    [ 18881, -18818,  32735, -12405,  32767,  -8833,   6193, -32768],  # classe 0 normal,
    [  5577, -32740,  -5178,  10644, -32768,   6115,  -5448,  32767],  # classe 1 desbalanceamento,
    [ 14415,  -5288, -32762,   4963,  32767,   6144,   4810, -32768],  # classe 2 desalinhamento,
    [  4947,  32767, -32768, -12227, -18300,   4240,  -3407,  29568],  # classe 3 rolamento,
]
DENSE_B = [-997, 13744, 3830, -22057]


def sat(v):
    return max(MINV, min(MAXV, v))


def scale(acc, shift=FRAC, relu=False):
    """Reescala com arredondamento simetrico, satura e (opcional) aplica ReLU.
    O >> do Python em inteiros negativos e aritmetico (floor), igual ao >>> do
    Verilog em vetores signed."""
    v = sat((acc + (1 << (shift - 1))) >> shift)
    return 0 if (relu and v < 0) else v


def conv_relu(img, H=32, W_=32, nf=8):
    """Convolucao 3x3, stride 1, padding 1, + bias + ReLU."""
    out = [[[0] * nf for _ in range(W_)] for _ in range(H)]
    for i in range(H):
        for j in range(W_):
            for f in range(nf):
                acc = BIAS[f] << FRAC
                for m in range(3):
                    for n in range(3):
                        r, c = i + m - 1, j + n - 1
                        px = img[r][c] if (0 <= r < H and 0 <= c < W_) else 0
                        acc += px * KER[f][m * 3 + n]
                out[i][j][f] = scale(acc, relu=True)
    return out


def maxpool(fmap, H=32, W_=32, nf=8):
    """Max pooling 2x2 stride 2."""
    out = [[[0] * nf for _ in range(W_ // 2)] for _ in range(H // 2)]
    for i in range(0, H, 2):
        for j in range(0, W_, 2):
            for f in range(nf):
                out[i // 2][j // 2][f] = max(
                    fmap[i][j][f], fmap[i][j + 1][f],
                    fmap[i + 1][j][f], fmap[i + 1][j + 1][f])
    return out


def gap(pmap, nf=8, shift=8):
    """Global average pooling: soma e divide por 2^shift."""
    feats = []
    for f in range(nf):
        acc = sum(pmap[i][j][f] for i in range(len(pmap)) for j in range(len(pmap[0])))
        feats.append(scale(acc, shift=shift, relu=True))
    return feats


def dense(feats, nc=4):
    """Camada densa + argmax (empate -> menor indice)."""
    scores = []
    for k in range(nc):
        acc = DENSE_B[k] << FRAC
        for i, fv in enumerate(feats):
            acc += fv * DENSE_W[k][i]
        scores.append(scale(acc, relu=False))
    best = 0
    for k in range(1, nc):
        if scores[k] > scores[best]:
            best = k
    return scores, best


def run(img):
    c = conv_relu(img)
    p = maxpool(c)
    f = gap(p)
    s, k = dense(f)
    return c, p, f, s, k
