#!/usr/bin/env python3
"""
Passo 02 -- Gera os espectrogramas 32x32 (Q1.15) e divide treino/validacao/teste.

Divisao POR TEMPO dentro de cada arquivo: primeiros 70% -> treino,
proximos 15% -> validacao, ultimos 15% -> teste (com 0.5 s de guarda entre as
fatias). Assim nenhuma imagem de teste compartilha amostras com o treino.

Saida: dados/processado/espectrogramas/dataset.npz
    X_treino, y_treino, g_treino (grupo = arquivo de origem), idem _valid e _teste
    arquivos: nomes dos arquivos de origem

    python python/scripts/02_gerar_espectrogramas.py
"""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma.espectrograma import quadros_fft, comprime, imagens


def main():
    C.DIR_ESPEC.mkdir(parents=True, exist_ok=True)
    arquivos = sorted(C.DIR_BRUTOS.glob("*.npy"))
    if not arquivos:
        sys.exit("Rode antes o passo 01 (01_converter_csv.py)")
    guarda = int(C.GUARDA_S * C.FS_ORIGINAL)
    out = {k: ([], [], []) for k in ("treino", "valid", "teste")}
    nomes = []
    for gi, arq in enumerate(arquivos):
        nome = arq.stem
        nomes.append(nome)
        cls = C.classe_do_arquivo(nome)
        x = np.load(arq, mmap_mode="r")[:, C.CANAL].astype(np.float64)
        n = len(x)
        a, b = int(n * C.FRACAO_TREINO), int(n * (C.FRACAO_TREINO + C.FRACAO_VALID))
        fatias = {"treino": x[:a], "valid": x[a + guarda:b], "teste": x[b + guarda:]}
        msg = []
        for k, seg in fatias.items():
            im = imagens(comprime(quadros_fft(seg)))
            out[k][0].append(im)
            out[k][1].append(np.full(len(im), cls, np.int8))
            out[k][2].append(np.full(len(im), gi, np.int16))
            msg.append(f"{k}={len(im)}")
        print(f"{nome:26s} classe={C.CLASSES[cls]:16s} " + " ".join(msg), flush=True)

    salvar = {"arquivos": np.array(nomes)}
    for k, (X, y, g) in out.items():
        salvar[f"X_{k}"] = np.concatenate(X)
        salvar[f"y_{k}"] = np.concatenate(y)
        salvar[f"g_{k}"] = np.concatenate(g)
    np.savez_compressed(C.DIR_ESPEC / "dataset.npz", **salvar)
    print("\nImagens por classe:")
    for k in out:
        cont = np.bincount(salvar[f"y_{k}"], minlength=4)
        print(f"  {k:7s}: " + ", ".join(f"{c}={n}" for c, n in zip(C.CLASSES, cont)))


if __name__ == "__main__":
    main()
