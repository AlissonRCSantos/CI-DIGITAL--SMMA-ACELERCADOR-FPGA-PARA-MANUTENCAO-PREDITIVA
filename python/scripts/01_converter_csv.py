#!/usr/bin/env python3
"""
Passo 01 -- Converte os CSVs do dataset (9.7 GB) em arquivos .npy compactos.

Le apenas as colunas dos acelerometros do mancal A (Canal1 = x_A, Canal2 = y_A),
em blocos (usa pouca RAM), e grava float32 em dados/processado/brutos/.
So precisa ser rodado UMA vez. Requer apenas numpy.

    python python/scripts/01_converter_csv.py
"""
import os, sys, time, itertools
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C

BLOCO = 1_000_000   # linhas por leitura

def converte(csv: Path, npy: Path):
    partes = []
    with open(csv, "r") as fh:
        next(fh)                                   # cabecalho
        while True:
            linhas = list(itertools.islice(fh, BLOCO))
            if not linhas:
                break
            partes.append(np.loadtxt(linhas, delimiter=",", usecols=C.COLUNAS_CSV,
                                     dtype=np.float32, ndmin=2))
    x = np.concatenate(partes)
    tmp = npy.with_suffix(".tmp.npy")
    np.save(tmp, x)
    os.replace(tmp, npy)          # grava de forma atomica (seguro se interromper)
    return x.shape[0]

def ok(npy: Path) -> bool:
    """Arquivo ja convertido e integro?"""
    try:
        return np.load(npy, mmap_mode="r").shape[0] > 0
    except Exception:
        return False


def main():
    C.DIR_BRUTOS.mkdir(parents=True, exist_ok=True)
    arquivos = sorted(C.DIR_CSV.glob("*.csv"))
    if not arquivos:
        sys.exit(f"Nenhum CSV em {C.DIR_CSV}")
    for i, csv in enumerate(arquivos, 1):
        nome = csv.stem.replace("Unbalalnce", "Unbalance")   # corrige erro de digitacao
        npy = C.DIR_BRUTOS / f"{nome}.npy"
        if ok(npy):
            print(f"[{i:2d}/{len(arquivos)}] {nome}: ja convertido")
            continue
        t = time.time()
        n = converte(csv, npy)
        print(f"[{i:2d}/{len(arquivos)}] {nome}: {n} amostras ({n / C.FS_ORIGINAL:.0f} s) "
              f"em {time.time() - t:.0f} s", flush=True)

if __name__ == "__main__":
    main()
