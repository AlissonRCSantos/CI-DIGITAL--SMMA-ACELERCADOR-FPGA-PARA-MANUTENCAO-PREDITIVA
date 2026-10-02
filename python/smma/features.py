"""
smma/features.py -- Vetor de caracteristicas do CLASSIFICADOR NUMERICO (PBL 3.5).

O enunciado (secao 3.5) exige que o classificador receba caracteristicas
extraidas da FFT, do filtro LMS e da etapa de estimacao matricial. Este
modulo e a ESPECIFICACAO desse bloco: tudo aqui e reproduzido no hardware.

Decisao de janelamento
----------------------
Uma decisao do classificador cobre 32 quadros de FFT consecutivos (o mesmo
alcance da imagem 32x32 da CNN, ~320 ms). Isso faz os dois classificadores
serem diretamente comparaveis e deixa as features bem menos ruidosas do que
seriam em um unico quadro de 10 ms.

As 12 caracteristicas
---------------------
  FFT (8)   -- espectro medio dos 32 quadros, bins 1..31 (bin 0 = DC descartado)
      0 r_1x      mag[1] / E        1x da rotacao (50 Hz)  -> DESBALANCEAMENTO
      1 r_2x      mag[2] / E        2x (100 Hz)            -> DESALINHAMENTO
      2 r_3x      mag[3] / E        3x (150 Hz)
      3 r_banda1  sum(mag[4:8])  / E    200-400 Hz   (BPFO ~179, BPFI ~272 Hz)
      4 r_banda2  sum(mag[8:16]) / E    400-800 Hz
      5 r_banda3  sum(mag[16:32])/ E    800-1600 Hz  -> ROLAMENTO (alta freq.)
      6 log2E     log2 da energia total  -> nivel absoluto (carga/severidade)
      7 centroide centro de massa espectral, normalizado

      Os seis primeiros sao RAZOES: nao dependem do nivel absoluto, entao
      sobrevivem a mudanca de carga -- que e justamente onde a CNN se degrada
      (89% a 0 Nm contra 65% balanceado a 4 Nm).

  LMS (1)
      8 r_lms     E[e^2]/E[x^2], residuo do preditor linear de 8 taps.
                  Sinal periodico (desbalanceamento) e previsivel -> residuo
                  baixo; impulsivo/banda larga (rolamento) -> residuo alto.

  Estimacao matricial / Yule-Walker (3)
      9  a1
      10 a2       coeficientes AR(3), obtidos resolvendo R a = r
      11 a3       (a mesma conta que autocorrelacao_yw + gauss_jordan_inv
                   fazem no hardware)

Formato numerico: todas as features sao levadas para Q1.15 com sinal
(-1.0 .. +0.99997), que e o formato ja usado por FFT, LMS e CNN.
"""
import numpy as np

import config as C

N_FEATURES = 12
NOMES = ["r_1x", "r_2x", "r_3x", "r_banda1", "r_banda2", "r_banda3",
         "log2E", "centroide", "r_lms", "a1", "a2", "a3"]

Q = 1 << C.FRAC                 # 32768
ORDEM_AR = 3                    # AR(3) -> matriz 3x3 (cabe no limite 4x4 do PBL)
ESCALA_AR = 2.0                 # divisor que traz a1..a3 para dentro de Q1.15
N_TAPS_LMS = 8                  # igual ao LMS_Filter_Top (enunciado 3.4)


def _mag_hardware(frames: np.ndarray) -> np.ndarray:
    """|X[k]| como o HARDWARE calcula: FFT/16 + alpha-max-beta-min.

    Usa a mesma aproximacao de magnitude do FFT_Magnitude.v (max + min/4 +
    min/8) em vez do modulo exato -- as features precisam ser as que o
    classificador vera em silicio, nao as ideais.
    """
    X = np.fft.rfft(frames, axis=1)[:, :C.NBINS] / 16.0     # SCALE_MASK = 0b001111
    re, im = np.abs(X.real), np.abs(X.imag)
    hi, lo = np.maximum(re, im), np.minimum(re, im)
    return hi + lo / 4.0 + lo / 8.0


def _features_fft(spec: np.ndarray) -> list:
    """8 caracteristicas do espectro medio (vetor de 32 bins)."""
    corpo = spec[1:]                       # descarta DC
    E = corpo.sum() + 1e-9
    r1, r2, r3 = spec[1] / E, spec[2] / E, spec[3] / E
    b1 = spec[4:8].sum() / E
    b2 = spec[8:16].sum() / E
    b3 = spec[16:32].sum() / E
    # log2 da energia, reescalado para caber em Q1.15 (energia >> 1 em Q1.15)
    log2E = np.log2(E + 1e-9) / 16.0
    centro = float((np.arange(1, 32) * corpo).sum() / E) / 32.0
    return [r1, r2, r3, b1, b2, b3, log2E, centro]


def _feature_lms(x: np.ndarray) -> float:
    """Residuo do preditor linear de 8 taps (solucao de minimos quadrados).

    O LMS adaptativo do hardware converge para esta mesma solucao; usar a
    solucao fechada aqui evita depender do transiente de convergencia e e o
    que o filtro entrega em regime permanente.
    """
    n = len(x)
    if n <= N_TAPS_LMS:
        return 0.0
    X = np.lib.stride_tricks.sliding_window_view(x, N_TAPS_LMS)[:-1]
    d = x[N_TAPS_LMS:]
    try:
        w, *_ = np.linalg.lstsq(X, d, rcond=None)
        e = d - X @ w
        return float(np.mean(e ** 2) / (np.mean(d ** 2) + 1e-12))
    except np.linalg.LinAlgError:
        return 1.0


def _features_ar(x: np.ndarray) -> list:
    """Coeficientes AR(3) por Yule-Walker: resolve R a = r.

    Replica a cadeia autocorrelacao_yw -> gauss_jordan_inv do hardware:
    monta a matriz de autocorrelacao (Toeplitz) e a inverte.

    Saida dividida por 2 (ESCALA_AR): medido no dataset, a1 chega a -1.52 e
    NAO caberia em Q1.15 (-1.0 .. +0.99997). Dividir por 2 traz os tres
    coeficientes para dentro da faixa sem perder informacao -- a arvore so
    aprende os limiares ja na metade do valor. Assim TODAS as 12 features
    usam o mesmo formato Q1.15 do resto do sistema, sem caso especial no
    hardware.
    """
    p = ORDEM_AR
    x = x - x.mean()
    denom = np.dot(x, x) + 1e-12
    r = np.array([np.dot(x[:len(x) - k], x[k:]) / denom for k in range(p + 1)])
    R = np.array([[r[abs(i - j)] for j in range(p)] for i in range(p)])
    try:
        # pivo proximo de zero -> matriz singular; o hardware sinaliza
        # 'singular' e o classificador recebe zeros (estado degenerado).
        if abs(np.linalg.det(R)) < 1e-9:
            return [0.0] * p
        a = np.linalg.solve(R, r[1:p + 1]) / ESCALA_AR
        return [float(v) for v in a]
    except np.linalg.LinAlgError:
        return [0.0] * p


def extrai(sinal_decimado: np.ndarray, mags: np.ndarray,
           i0: int, n_quadros: int) -> list:
    """Vetor de 12 features para UMA decisao do classificador.

    sinal_decimado : sinal ja filtrado e decimado (3.2 kHz), em Q1.15 float
    mags           : magnitudes |X| de todos os quadros (n_quadros_total, 32)
    i0, n_quadros  : faixa de quadros que compoe esta decisao
    """
    spec = mags[i0:i0 + n_quadros].mean(axis=0)
    # amostras de tempo cobertas por esses quadros
    a = i0 * C.HOP
    b = a + (n_quadros - 1) * C.HOP + C.NFFT
    seg = sinal_decimado[a:b]
    return _features_fft(spec) + [_feature_lms(seg)] + _features_ar(seg)


def para_q15(F: np.ndarray) -> np.ndarray:
    """float -> inteiro Q1.15 com saturacao (formato de entrada do hardware)."""
    return np.clip(np.round(F * Q), -Q, Q - 1).astype(np.int16)
