#!/usr/bin/env python3
"""
Passo 06 -- Gera o vetor de caracteristicas do classificador numerico (PBL 3.5).

Usa exatamente a MESMA divisao treino/validacao/teste por tempo da CNN
(70/15/15 com 0.5 s de guarda), para que os dois classificadores possam ser
comparados nas MESMAS janelas -- sem isso qualquer diferenca de acuracia
poderia ser so efeito de particao diferente.

Saida: dados/processado/features/features.npz
    X_* (n, 12) float64, y_* (n,) classe, g_* (n,) arquivo de origem

    python python/scripts/06_gerar_features.py
"""
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import features as F
from smma.espectrograma import coef_fir, FUNDO_ESCALA_G

DIR_FEAT = C.RAIZ / "dados" / "processado" / "features"


def cadeia_frontend(x_g: np.ndarray):
    """Sinal bruto (g) -> (sinal decimado Q1.15, magnitudes por quadro).

    Mesma cadeia do espectrograma da CNN: escala do sensor, FIR anti-alias,
    decimacao x8 e FFT de 64 pontos a cada 32 amostras (10 ms).
    """
    Q = 1 << C.FRAC
    xq = np.clip(np.round(x_g / FUNDO_ESCALA_G * Q), -Q, Q - 1)
    h = coef_fir()
    y = np.convolve(xq.astype(np.float64), h, mode="valid")[::C.DECIMACAO]
    y = np.clip(np.round(y / Q), -Q, Q - 1)
    frames = np.lib.stride_tricks.sliding_window_view(y, C.NFFT)[::C.HOP]
    return y, F._mag_hardware(frames)


def main():
    DIR_FEAT.mkdir(parents=True, exist_ok=True)
    arquivos = sorted(C.DIR_BRUTOS.glob("*.npy"))
    if not arquivos:
        sys.exit("Rode antes o passo 01b (01b_converter_mat.py)")

    guarda_q = int(C.GUARDA_S * C.FS_ORIGINAL / C.DECIMACAO / C.HOP)  # em quadros
    out = {k: ([], [], []) for k in ("treino", "valid", "teste")}
    nomes = []

    for gi, arq in enumerate(arquivos):
        t0 = time.time()
        nome = arq.stem
        nomes.append(nome)
        cls = C.classe_do_arquivo(nome)

        x = np.load(arq, mmap_mode="r")[:, C.CANAL].astype(np.float64)
        sinal, mags = cadeia_frontend(x)
        nq = mags.shape[0]

        # divisao POR TEMPO, identica a do passo 02
        i_tr = int(nq * C.FRACAO_TREINO)
        i_va = int(nq * (C.FRACAO_TREINO + C.FRACAO_VALID))
        faixas = {
            "treino": (0, i_tr - guarda_q),
            "valid":  (i_tr + guarda_q, i_va - guarda_q),
            "teste":  (i_va + guarda_q, nq),
        }

        cont = {}
        for parte, (ini, fim) in faixas.items():
            # uma decisao a cada PASSO_IMAGEM quadros, cobrindo NQUADROS
            i0s = list(range(ini, fim - C.NQUADROS + 1, C.PASSO_IMAGEM))
            cont[parte] = len(i0s)
            if not i0s:
                continue
            # espectrais: por janela (barato)
            esp = np.array([F.features_espectrais_int(
                                mags[i0:i0 + C.NQUADROS].astype(np.int64).sum(axis=0))
                            for i0 in i0s], dtype=np.int64)
            # temporais: em LOTE -- o LMS tem 8 taps por amostra e em Python
            # escalar nao terminaria em tempo util
            L = (C.NQUADROS - 1) * C.HOP + C.NFFT
            segs = np.stack([sinal[i0*C.HOP:i0*C.HOP + L] for i0 in i0s]).astype(np.int64)
            lms = F.feature_lms_batch(segs)[:, None]
            rho = F.features_autocorr_batch(segs)
            Xs = np.hstack([esp, lms, rho]) / (1 << C.FRAC)
            out[parte][0].append(np.asarray(Xs, dtype=np.float64))
            out[parte][1].append(np.full(len(Xs), cls, np.int8))
            out[parte][2].append(np.full(len(Xs), gi, np.int16))

        print(f"{nome:<26} classe={C.CLASSES[cls]:<16} "
              f"treino={cont['treino']:4d} valid={cont['valid']:3d} "
              f"teste={cont['teste']:3d}  ({time.time()-t0:.1f}s)", flush=True)

    dados = {"arquivos": np.array(nomes)}
    for parte in ("treino", "valid", "teste"):
        dados[f"X_{parte}"] = np.concatenate(out[parte][0])
        dados[f"y_{parte}"] = np.concatenate(out[parte][1])
        dados[f"g_{parte}"] = np.concatenate(out[parte][2])

    np.savez_compressed(DIR_FEAT / "features.npz", **dados)

    print("\nAmostras por classe:")
    for parte in ("treino", "valid", "teste"):
        y = dados[f"y_{parte}"]
        d = ", ".join(f"{C.CLASSES[c]}={int((y == c).sum())}" for c in range(4))
        print(f"  {parte:7s}: {d}")
    print(f"\n{dados['X_treino'].shape[1]} caracteristicas: {', '.join(F.NOMES)}")
    print(f"gravado em {DIR_FEAT/'features.npz'}")


if __name__ == "__main__":
    main()
