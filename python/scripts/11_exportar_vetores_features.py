#!/usr/bin/env python3
"""
Passo 11 -- Gera os vetores de teste dos dois extratores de caracteristicas.

    quartus/vetores/feat_teste.hex   8 janelas: 1024 |X[k]| + as 8 espectrais
    quartus/vetores/temp_teste.hex   6 janelas: 1056 amostras + as 4 temporais

As janelas sao REAIS e vem todas da particao de TESTE (nunca de treino: um
vetor de verificacao tirado do treino nao prova nada sobre o hardware, so
repete o que o modelo ja viu). A selecao e a PRIMEIRA janela de teste de cada
arquivo listado, para que o script seja deterministico e reexecutavel.

Os valores esperados saem das funcoes inteiras de smma/features.py -- as
mesmas que os testbenches comparam BIT A BIT. Nao e rigor gratuito: os
limiares da arvore foram aprendidos sobre estes numeros, entao uma diferenca
de poucos LSB nao "quase acerta", ela move a fronteira de decisao.

    python python/scripts/11_exportar_vetores_features.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import features as F
from smma.espectrograma import coef_fir, FUNDO_ESCALA_G

DIR_VET = C.DIR_VET

# Janelas do vetor ESPECTRAL: as 4 classes x cargas variadas.
CASOS_ESP = [
    "0Nm_Normal", "0Nm_Unbalance_3318mg", "0Nm_Misalign_05", "0Nm_BPFO_10",
    "2Nm_Normal", "2Nm_BPFI_30", "4Nm_Misalign_03", "4Nm_Unbalance_1751mg",
]
# Janelas do vetor TEMPORAL: subconjunto (o LMS e recursivo e cada janela
# custa 1056 iteracoes x 8 taps em Python escalar).
CASOS_TEMP = [
    "0Nm_Normal", "0Nm_Unbalance_3318mg", "0Nm_Misalign_05", "0Nm_BPFO_10",
    "4Nm_Normal", "2Nm_BPFI_30",
]

# Amostras decimadas cobertas por uma janela de 32 quadros
L_JANELA = (C.NQUADROS - 1) * C.HOP + C.NFFT          # 1056


def frontend(nome: str):
    """Arquivo bruto -> (sinal decimado Q1.15, magnitudes por quadro).

    Mesma cadeia de 06_gerar_features.py, que por sua vez e a mesma do
    espectrograma da CNN -- se divergir, os vetores validam o hardware contra
    uma aritmetica que nao e a treinada.
    """
    Q = 1 << C.FRAC
    x = np.load(C.DIR_BRUTOS / f"{nome}.npy", mmap_mode="r")[:, C.CANAL]
    xq = np.clip(np.round(np.asarray(x, np.float64) / FUNDO_ESCALA_G * Q), -Q, Q - 1)
    y = np.convolve(xq, coef_fir(), mode="valid")[::C.DECIMACAO]
    y = np.clip(np.round(y / Q), -Q, Q - 1).astype(np.int64)
    quadros = np.lib.stride_tricks.sliding_window_view(y, C.NFFT)[::C.HOP]
    return y, F._mag_hardware(quadros)


def inicio_teste(n_quadros: int) -> int:
    """Primeiro quadro da particao de teste, com a mesma guarda do passo 06."""
    guarda = int(C.GUARDA_S * C.FS_ORIGINAL / C.DECIMACAO / C.HOP)
    i_va = int(n_quadros * (C.FRACAO_TREINO + C.FRACAO_VALID))
    return i_va + guarda


def h16(v: int) -> str:
    """Inteiro com sinal -> 4 digitos hex de 16 bits (complemento de dois)."""
    return f"{int(v) & 0xFFFF:04X}"


def main():
    DIR_VET.mkdir(parents=True, exist_ok=True)

    # ---------------- vetor espectral ----------------
    linhas = [h16(len(CASOS_ESP))]
    for nome in CASOS_ESP:
        _, mags = frontend(nome)
        i0 = inicio_teste(mags.shape[0])
        bloco = mags[i0:i0 + C.NQUADROS].astype(np.int64)
        assert bloco.shape == (C.NQUADROS, 32), f"{nome}: janela incompleta"
        linhas += [h16(v) for v in bloco.ravel()]
        linhas += [h16(v) for v in F.features_espectrais_int(bloco.sum(axis=0))]
        print(f"  espectral  {nome}")
    (DIR_VET / "feat_teste.hex").write_text("\n".join(linhas) + "\n")

    # ---------------- vetor temporal ----------------
    linhas = [h16(len(CASOS_TEMP)), h16(L_JANELA)]
    for nome in CASOS_TEMP:
        sinal, mags = frontend(nome)
        i0 = inicio_teste(mags.shape[0])
        seg = sinal[i0 * C.HOP:i0 * C.HOP + L_JANELA]
        assert len(seg) == L_JANELA, f"{nome}: janela incompleta"
        esperado = [F.feature_lms_int(seg)] + F.features_autocorr_int(seg)
        linhas += [h16(v) for v in seg]
        linhas += [h16(v) for v in esperado]
        print(f"  temporal   {nome:<24} r_lms={esperado[0]:6d} "
              f"rho={esperado[1:]}")
    (DIR_VET / "temp_teste.hex").write_text("\n".join(linhas) + "\n")

    print(f"\ngravados em {DIR_VET}")


if __name__ == "__main__":
    main()
