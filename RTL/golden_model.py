#!/usr/bin/env python3
"""Modelo de referencia (golden model) bit-exato da CNN em ponto fixo Q1.15.
Usado para gerar os valores esperados dos testbenches."""

W, FRAC = 16, 15
MAXV, MINV = (1 << (W - 1)) - 1, -(1 << (W - 1))

# ---- Kernels (indice = filtro, lista de 9 taps em ordem linha*3+coluna) ----
KER = [
    [-8192,      0,   8192, -16384,      0,  16384,  -8192,      0,   8192],  # F0 Sobel X
    [-8192, -16384,  -8192,      0,      0,      0,   8192,  16384,   8192],  # F1 Sobel Y
    [    0,  -4096,      0,  -4096,  16384,  -4096,      0,  -4096,      0],  # F2 Laplaciano
    [ 3641,   3641,   3641,   3641,   3641,   3641,   3641,   3641,   3641],  # F3 Media
    [-16384, -8192,      0,  -8192,      0,   8192,      0,   8192,  16384],  # F4 Diag
    [    0,  -8192, -16384,   8192,      0,  -8192,  16384,   8192,      0],  # F5 Diag
    [    0,      0,      0,  -8192,  16384,  -8192,      0,      0,      0],  # F6 Passa-alta
    [    0,      0,      0,      0,  16384,      0,      0,      0,      0],  # F7 Centro
]
BIAS = [0, 256, -256, 512, -512, 1024, -1024, 2048]

DENSE_W = [
    [-16384, -16384, -16384,  16384,     0,     0, -16384,     0],  # classe 0
    [-16384,  16384, -16384,      0,     0,     0, -16384,     0],  # classe 1
    [ 16384, -16384, -16384,      0,     0,     0, -16384,     0],  # classe 2
    [-16384, -16384,  16384,      0,     0,     0,  16384,     0],  # classe 3
]
DENSE_B = [0, -512, -512, -1024]


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
