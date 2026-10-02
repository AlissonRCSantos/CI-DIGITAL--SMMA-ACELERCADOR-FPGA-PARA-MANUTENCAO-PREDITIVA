#!/usr/bin/env python3
"""
Passo 09 -- Exporta o front-end de aquisicao para o hardware.

Gera:
    RTL/vetores/fir_coef.hex    63 coeficientes Q1.15 do FIR anti-aliasing
    RTL/vetores/fir_teste.hex   estimulo real + saida esperada do decimador

Nota sobre arredondamento
-------------------------
O modelo do espectrograma usa np.round (meio-para-par, convencao do numpy).
O hardware usa meio-para-cima, que e a regra ja empregada em FP_Mult_Unit e
no butterfly da FFT -- manter UMA regra em todo o projeto vale mais do que
copiar a do numpy. As duas so divergem quando o valor cai exatamente em .5:
medido em 192 mil amostras decimadas do dataset, isso ocorre em 0,0036%
delas, e a diferenca e de 1 LSB. Os vetores de teste abaixo usam a regra do
HARDWARE, de modo que a verificacao e bit-exata.

    python python/scripts/09_exportar_frontend.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma.espectrograma import coef_fir, FUNDO_ESCALA_G

DIR_VET = C.DIR_RTL / "vetores"
Q = 1 << C.FRAC
N_TESTE = 4096          # amostras de entrada gravadas para o testbench


def fir_decima_hw(xq: np.ndarray, h: np.ndarray) -> np.ndarray:
    """FIR + decimacao com a aritmetica EXATA do hardware (inteiros).

    y[k] = sat( (sum_i h[i]*x[n-i] + 2^14) >> 15 ),  n = k*DECIM + N_TAPS-1
    """
    n_taps = len(h)
    saidas = []
    for n in range(n_taps - 1, len(xq), C.DECIMACAO):
        janela = xq[n - n_taps + 1: n + 1][::-1]      # x[n], x[n-1], ...
        acc = int(np.dot(janela.astype(np.int64), h.astype(np.int64)))
        v = (acc + (1 << (C.FRAC - 1))) >> C.FRAC     # meio-para-cima
        saidas.append(int(np.clip(v, -Q, Q - 1)))
    return np.array(saidas, dtype=np.int64)


def main():
    DIR_VET.mkdir(parents=True, exist_ok=True)
    h = coef_fir()
    assert len(h) == C.NFIR, f"esperado {C.NFIR} taps, obtido {len(h)}"

    # ---- ROM de coeficientes ----
    (DIR_VET / "fir_coef.hex").write_text(
        "\n".join(f"{int(c) & 0xFFFF:04X}" for c in h) + "\n")
    print(f"coeficientes: {len(h)} taps, simetrico={np.array_equal(h, h[::-1])}, "
          f"ganho DC={h.sum()/Q:.6f}")

    # ---- estimulo real + saida esperada ----
    brutos = sorted(C.DIR_BRUTOS.glob("*.mat.npy")) or sorted(C.DIR_BRUTOS.glob("*.npy"))
    if not brutos:
        sys.exit("Rode antes o passo 01b")
    # arquivo com conteudo espectral rico (falha de rolamento) para exercitar
    # o filtro em toda a banda, nao so em baixa frequencia
    alvo = next((p for p in brutos if "BPFO_10" in p.stem), brutos[0])
    x = np.load(alvo, mmap_mode="r")[:N_TESTE, C.CANAL].astype(np.float64)
    xq = np.clip(np.round(x / FUNDO_ESCALA_G * Q), -Q, Q - 1).astype(np.int64)
    y = fir_decima_hw(xq, h)

    linhas = [f"{len(xq):04X}", f"{len(y):04X}"]
    linhas += [f"{int(v) & 0xFFFF:04X}" for v in xq]
    linhas += [f"{int(v) & 0xFFFF:04X}" for v in y]
    (DIR_VET / "fir_teste.hex").write_text("\n".join(linhas) + "\n")

    print(f"estimulo:     {alvo.stem}, {len(xq)} amostras @25.6 kHz")
    print(f"esperado:     {len(y)} amostras @3.2 kHz "
          f"(faixa {y.min()}..{y.max()})")
    print(f"gravado em {DIR_VET}")


if __name__ == "__main__":
    main()
