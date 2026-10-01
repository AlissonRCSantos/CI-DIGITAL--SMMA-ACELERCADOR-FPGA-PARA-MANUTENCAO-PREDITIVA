"""
smma/golden.py -- Modelo BIT-EXATO da CNN do RTL, vetorizado com numpy.

Faz exatamente as mesmas contas inteiras do hardware (Q1.15, acumuladores
largos, arredondamento "+2^(s-1) e >>s", saturacao em 16 bits, ReLU, max
pooling 2x2, GAP por >>8, camada densa e argmax com empate -> menor indice).
E a versao "em lote" do RTL/golden_model.py: processa milhares de imagens de
uma vez para medir a acuracia REAL que o FPGA tera.

Pesos no formato:
    ker  : (8, 9)  inteiros Q1.15, tap = linha*3 + coluna
    bias : (8,)
    dw   : (4, 8)
    db   : (4,)
"""
import numpy as np

FRAC = 15
MAXV, MINV = (1 << 15) - 1, -(1 << 15)


def _scale(acc, shift=FRAC, relu=False):
    v = np.clip((acc + (1 << (shift - 1))) >> shift, MINV, MAXV)
    return np.maximum(v, 0) if relu else v


def conv_relu(img, ker, bias):
    """img (n,32,32) int -> (n,32,32,8). Padding 1 com zeros, stride 1."""
    n, H, W = img.shape
    p = np.zeros((n, H + 2, W + 2), np.int64)
    p[:, 1:-1, 1:-1] = img
    acc = np.broadcast_to(np.asarray(bias, np.int64) << FRAC, (n, H, W, 8)).copy()
    for m in range(3):
        for k in range(3):
            acc += p[:, m:m + H, k:k + W, None] * np.asarray(ker, np.int64)[:, m * 3 + k]
    return _scale(acc, relu=True)


def maxpool(f):
    n, H, W, c = f.shape
    return f.reshape(n, H // 2, 2, W // 2, 2, c).max(axis=(2, 4))


def gap(p, shift=8):
    return _scale(p.sum(axis=(1, 2)), shift=shift, relu=True)


def dense(feat, dw, db):
    acc = (np.asarray(db, np.int64) << FRAC) + feat @ np.asarray(dw, np.int64).T
    return _scale(acc)


def run(img, ker, bias, dw, db):
    """Retorna (features, scores, classe) -- argmax com empate no menor indice."""
    img = np.asarray(img, np.int64)
    feat = gap(maxpool(conv_relu(img, ker, bias)))
    sc = dense(feat, dw, db)
    return feat, sc, sc.argmax(axis=1)     # np.argmax ja devolve o 1o maximo
