"""
smma/espectrograma.py -- Geracao do espectrograma 32x32 de ENTRADA da CNN.

Este arquivo e a ESPECIFICACAO do caminho FFT -> espectrograma do hardware.
Tudo e feito em inteiros Q1.15 (exceto a FFT, feita em float e depois
quantizada; a diferenca para uma FFT em ponto fixo e pequena).

Cadeia (por amostra do acelerometro y_A, 25.6 kHz):
  1. Escala do sensor : x_q = sat(x[g] / FUNDO_ESCALA_G)        -> Q1.15
  2. FIR anti-alias   : 63 taps Q1.15 (passa-baixa 1.6 kHz)
  3. Decimacao x8     : 25.6 kHz -> 3.2 kHz
  4. FFT 64 pontos    : janela retangular, a cada 32 amostras (10 ms)
                        resultado dividido por 16 (escala 1/2 em 4 dos 6
                        estagios radix-2; margem medida no dataset: pico
                        maximo ~50% do fundo de escala)
  5. Magnitude        : |X| em Q1.15, bins 0..31 (50 Hz por bin)
  6. Compressao log2  : aproximacao de Mitchell (so priority encoder + shift):
                          m = |X|+1, e = floor(log2 m)
                          pixel = e*2048 + ((m - 2^e) << 11) >> e      (0..32767)
  7. Imagem           : 32 FFTs consecutivas -> matriz 32x32
                          linha i  = bin de frequencia i (0 = DC ... 31 = 1550 Hz)
                          coluna j = quadro de tempo j (10 ms cada)
                        enviada ao CNN_Top em ordem raster (linha por linha).
"""
import numpy as np
import config as C

FUNDO_ESCALA_G = 32.0          # +-32 g = +-1.0 em Q1.15
ESCALA_FFT = 16                # divisao total aplicada dentro da FFT
Q = 1 << C.FRAC                # 32768
MAXV, MINV = Q - 1, -Q


def coef_fir() -> np.ndarray:
    """FIR passa-baixa 63 taps, corte 1.4 kHz @ 25.6 kHz, coef. Q1.15 inteiros."""
    n = np.arange(C.NFIR) - (C.NFIR - 1) / 2
    fc = 1400 / C.FS_ORIGINAL                       # corte normalizado
    h = 2 * fc * np.sinc(2 * fc * n) * np.hamming(C.NFIR)
    h /= h.sum()                                    # ganho DC = 1 (igual scipy.firwin)
    return np.round(h * Q).astype(np.int64)


def quadros_fft(x_g: np.ndarray) -> np.ndarray:
    """Sinal bruto (g, 25.6 kHz) -> matriz (n_quadros, 32) de |X| em Q1.15 (inteiro)."""
    xq = np.clip(np.round(x_g / FUNDO_ESCALA_G * Q), MINV, MAXV).astype(np.int64)
    h = coef_fir()
    # FIR + decimacao: calcula so as saidas que sobrevivem a decimacao
    y = np.convolve(xq.astype(np.float64), h, mode="valid")[::C.DECIMACAO]
    y = np.clip(np.round(y / Q), MINV, MAXV)                       # volta a Q1.15
    fr = np.lib.stride_tricks.sliding_window_view(y, C.NFFT)[::C.HOP]
    X = np.fft.rfft(fr, axis=1)[:, :C.NBINS] / ESCALA_FFT          # escala 1/16
    mag = np.clip(np.round(np.abs(X)), 0, MAXV).astype(np.int64)
    return mag


def comprime(mag: np.ndarray) -> np.ndarray:
    """|X| Q1.15 -> pixel Q1.15 (0..32767)."""
    if C.ESCALA == "linear":
        return np.clip(mag * 16, 0, MAXV).astype(np.int64)
    m = mag + 1
    e = np.floor(np.log2(m)).astype(np.int64)                      # priority encoder
    pix = e * 2048 + (((m - (1 << e)) << 11) >> e)
    return np.clip(pix, 0, MAXV).astype(np.int64)


def imagens(pix: np.ndarray, passo: int = C.PASSO_IMAGEM) -> np.ndarray:
    """Matriz (n_quadros, 32) -> imagens (n, 32, 32) com linha=bin, coluna=tempo."""
    if pix.shape[0] < C.NQUADROS:
        return np.zeros((0, C.NBINS, C.NQUADROS), np.int16)
    w = np.lib.stride_tricks.sliding_window_view(pix, C.NQUADROS, axis=0)[::passo]
    return w.astype(np.int16)          # (n, 32 bins, 32 quadros)
