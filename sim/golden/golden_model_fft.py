#!/usr/bin/env python3
# ============================================================================
# golden_model.py -- Modelo de referencia do modulo FFT do acelerador SMMA
#
# Gera dois modelos:
#   1) MODELO BIT-EXATO do hardware (FFT_Top.v): reproduz exatamente o
#      arredondamento, o escalonamento de 1/2 por estagio e a saturacao do
#      datapath em ponto fixo Q1.15. E usado para produzir os vetores
#      esperados dos testbenches auto-verificaveis.
#   2) MODELO IDEAL em ponto flutuante: FFT exata normalizada por N, usada
#      para quantificar o erro de quantizacao (entregavel 6.6 do enunciado:
#      "analise de eventuais diferencas numericas").
#
# Uso:
#     python3 golden_model.py              # relatorio de erro e casos de teste
#     python3 golden_model.py --vectors    # gera fft_vectors.vh para o testbench
#
# Nao depende de numpy: usa apenas a biblioteca padrao.
# ============================================================================

import cmath
import math
import sys

N = 64
LOG2N = 6
WIDTH = 16
FRAC = 15

Q_ONE = 1 << FRAC          # 32768
Q_MAX = (1 << (WIDTH - 1)) - 1   # +32767
Q_MIN = -(1 << (WIDTH - 1))      # -32768


# ---------------------------------------------------------------------------
# Primitivas de ponto fixo (espelham FP_Mult_Unit.v e FFT_Butterfly.v)
# ---------------------------------------------------------------------------
def sat16(v):
    """Satura um inteiro para a faixa de 16 bits com sinal."""
    if v > Q_MAX:
        return Q_MAX
    if v < Q_MIN:
        return Q_MIN
    return v


def to_q15(x):
    """Converte float para Q1.15 com arredondamento e saturacao."""
    return sat16(int(math.floor(x * Q_ONE + 0.5)))


def from_q15(v):
    """Converte Q1.15 de volta para float."""
    return v / Q_ONE


def mult_q15(a, b):
    """Multiplicacao Q1.15 x Q1.15 -> Q1.15.

    Replica FP_Mult_Unit com ROUNDING=1: produto de 32 bits, soma de meio LSB,
    deslocamento aritmetico de FRAC bits e saturacao.
    """
    prod = a * b                       # Q2.30 em 32 bits
    prod += (1 << (FRAC - 1))          # arredondamento "round half up"
    prod >>= FRAC                      # volta para Q1.15 (shift aritmetico)
    return sat16(prod)


# Mascara de escalonamento por estagio: bit i = 1 -> estagio (i+1) divide por 2.
# Deve ser identica ao parametro SCALE_MASK de FFT_Top.v. O padrao 0b001111
# escala os estagios 1..4 -> ganho total 1/16, que e a especificacao usada
# para treinar a CNN (python/smma/espectrograma.py: ESCALA_FFT = 16).
SCALE_MASK = 0b001111
ESCALA_FFT = 1 << bin(SCALE_MASK).count("1")   # 16


def scale_round_sat(v, do_scale):
    """(v + 0.5 LSB)/2 se do_scale, senao v -- com saturacao (estagio 6)."""
    return sat16(((v + 1) >> 1) if do_scale else v)


# ---------------------------------------------------------------------------
# Fatores de rotacao (identicos aos gravados em FFT_Twiddle_ROM.v)
# ---------------------------------------------------------------------------
def twiddle_rom():
    rom = []
    for k in range(N // 2):
        wr = to_q15(math.cos(2 * math.pi * k / N))
        wi = to_q15(-math.sin(2 * math.pi * k / N))
        rom.append((wr, wi))
    return rom


TWIDDLE = twiddle_rom()


def bit_reverse(idx, bits=LOG2N):
    r = 0
    for i in range(bits):
        if idx & (1 << i):
            r |= 1 << (bits - 1 - i)
    return r


# ---------------------------------------------------------------------------
# 1) MODELO BIT-EXATO DO HARDWARE
# ---------------------------------------------------------------------------
def fft_fixed(samples_re, samples_im):
    """FFT radix-2 DIT in-place, Q1.15, escala 1/2 nos estagios de SCALE_MASK.

    Reproduz ciclo a ciclo a aritmetica de FFT_Butterfly.v.
    Retorna (re[], im[]) em ordem natural de frequencia.
    """
    # Carga com inversao de bits (feita na escrita, como no hardware)
    re = [0] * N
    im = [0] * N
    for n in range(N):
        re[bit_reverse(n)] = samples_re[n]
        im[bit_reverse(n)] = samples_im[n]

    for s in range(1, LOG2N + 1):
        half = 1 << (s - 1)
        for b in range(N // 2):
            j = b & (half - 1)
            group = b >> (s - 1)
            p = (group << s) | j
            q = p | half
            k = j << (LOG2N - s)

            wr, wi = TWIDDLE[k]
            br, bi = re[q], im[q]
            ar, ai = re[p], im[p]

            # Multiplicacao complexa: 4 produtos saturados individualmente
            m_rr = mult_q15(br, wr)
            m_ii = mult_q15(bi, wi)
            m_ri = mult_q15(br, wi)
            m_ir = mult_q15(bi, wr)

            t_re = m_rr - m_ii          # 17 bits
            t_im = m_ri + m_ir

            # Butterfly com escala de 1/2 e saturacao
            sc = bool((SCALE_MASK >> (s - 1)) & 1)
            re[p] = scale_round_sat(ar + t_re, sc)
            im[p] = scale_round_sat(ai + t_im, sc)
            re[q] = scale_round_sat(ar - t_re, sc)
            im[q] = scale_round_sat(ai - t_im, sc)

    return re, im


def magnitude_fixed(re, im):
    """alpha-max plus beta-min: |X| ~= max + min/4 + min/8 (ver FFT_Magnitude.v)."""
    out = []
    for r, i in zip(re, im):
        a, b = abs(r), abs(i)
        hi, lo = (a, b) if a >= b else (b, a)
        out.append(hi + (lo >> 2) + (lo >> 3))
    return out


# ---------------------------------------------------------------------------
# 2) MODELO IDEAL (ponto flutuante)
# ---------------------------------------------------------------------------
def fft_ideal(samples_re, samples_im):
    """DFT exata dividida por ESCALA_FFT -- mesma escala da saida do hardware."""
    x = [complex(from_q15(r), from_q15(i))
         for r, i in zip(samples_re, samples_im)]
    out = []
    for k in range(N):
        acc = 0j
        for n in range(N):
            acc += x[n] * cmath.exp(-2j * cmath.pi * k * n / N)
        out.append(acc / ESCALA_FFT)
    return out


# ---------------------------------------------------------------------------
# Sinais de teste
# ---------------------------------------------------------------------------
def sig_impulse():
    """Impulso unitario: espectro deve ser constante em todos os bins."""
    re = [0] * N
    re[0] = Q_MAX
    return re, [0] * N


def sig_dc():
    """Nivel DC: toda a energia deve se concentrar no bin 0."""
    return [to_q15(0.125)] * N, [0] * N


def sig_tone(bin_k, amp=0.25, phase=0.0):
    """Senoide pura centrada no bin k (frequencia coerente com a janela)."""
    re = [to_q15(amp * math.cos(2 * math.pi * bin_k * n / N + phase))
          for n in range(N)]
    return re, [0] * N


def sig_motor():
    """Vibracao sintetica de motor: fundamental no bin 6 + harmonicas.

    Reproduz o exemplo do enunciado (picos em bins multiplos de 6, cujo MDC
    resulta na frequencia fundamental). Picos em 6, 12 e 18.
    """
    re = []
    for n in range(N):
        v = (0.250 * math.cos(2 * math.pi * 6 * n / N)
             + 0.125 * math.cos(2 * math.pi * 12 * n / N + 0.7)
             + 0.060 * math.cos(2 * math.pi * 18 * n / N + 1.3))
        re.append(to_q15(v))
    return re, [0] * N


TEST_CASES = [
    ("impulso",        sig_impulse()),
    ("dc",             sig_dc()),
    ("tom_bin4",       sig_tone(4)),
    ("tom_bin13",      sig_tone(13, 0.25, 0.4)),
    ("motor_6_12_18",  sig_motor()),
]


# ---------------------------------------------------------------------------
# Relatorio de erro: ponto fixo vs. ideal
# ---------------------------------------------------------------------------
def report():
    print("=" * 74)
    print(" MODELO DE REFERENCIA DA FFT DE 64 PONTOS - SMMA")
    print(" Formato Q1.15, radix-2 DIT, escala 1/2 em 4 dos 6 estagios (saida = X[k]/16)")
    print("=" * 74)

    for name, (sre, sim) in TEST_CASES:
        hre, him = fft_fixed(sre, sim)
        ideal = fft_ideal(sre, sim)

        err_re = [abs(from_q15(hre[k]) - ideal[k].real) for k in range(N)]
        err_im = [abs(from_q15(him[k]) - ideal[k].imag) for k in range(N)]
        max_err = max(max(err_re), max(err_im))
        rms = math.sqrt(sum(e * e for e in err_re + err_im) / (2 * N))

        # Energia do sinal ideal, para o calculo de SNR
        pot = sum(abs(c) ** 2 for c in ideal) / N
        ruido = sum(e * e for e in err_re) / N + sum(e * e for e in err_im) / N
        snr = 10 * math.log10(pot / ruido) if ruido > 0 else float('inf')

        print("\n--- %s ---" % name)
        print("  erro absoluto maximo : %.6f  (%.1f LSB de Q1.15)"
              % (max_err, max_err * Q_ONE))
        print("  erro RMS             : %.6f  (%.1f LSB)" % (rms, rms * Q_ONE))
        print("  SNR estimada         : %.1f dB" % snr)

        # Tres maiores bins pela magnitude aproximada (entrada do detector de picos)
        mag = magnitude_fixed(hre, him)
        top = sorted(range(N // 2), key=lambda k: mag[k], reverse=True)[:3]
        print("  3 maiores bins (0..31): %s" % sorted(top))


# ---------------------------------------------------------------------------
# Geracao dos vetores para o testbench Verilog
# ---------------------------------------------------------------------------
def emit_vectors(path="fft_vectors.vh"):
    lines = []
    lines.append("// ==========================================================")
    lines.append("// fft_vectors.vh -- GERADO POR golden_model.py, NAO EDITAR")
    lines.append("// Vetores bit-exatos do modelo de referencia da FFT de 64 pontos")
    lines.append("// ==========================================================")
    lines.append("")

    for idx, (name, (sre, sim)) in enumerate(TEST_CASES):
        hre, him = fft_fixed(sre, sim)
        mag = magnitude_fixed(hre, him)
        lines.append("// ---- caso %d: %s ----" % (idx, name))
        for n in range(N):
            lines.append("STIM_RE[%d][%d] = 16'h%04X;" % (idx, n, sre[n] & 0xFFFF))
        for n in range(N):
            lines.append("STIM_IM[%d][%d] = 16'h%04X;" % (idx, n, sim[n] & 0xFFFF))
        for k in range(N):
            lines.append("EXP_RE[%d][%d] = 16'h%04X;" % (idx, k, hre[k] & 0xFFFF))
        for k in range(N):
            lines.append("EXP_IM[%d][%d] = 16'h%04X;" % (idx, k, him[k] & 0xFFFF))
        for k in range(N):
            lines.append("EXP_MAG[%d][%d] = 16'h%04X;" % (idx, k, mag[k] & 0xFFFF))
        lines.append("")

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("Vetores gravados em %s (%d casos, %d pontos cada)"
          % (path, len(TEST_CASES), N))


if __name__ == "__main__":
    if "--vectors" in sys.argv:
        emit_vectors()
    else:
        report()
