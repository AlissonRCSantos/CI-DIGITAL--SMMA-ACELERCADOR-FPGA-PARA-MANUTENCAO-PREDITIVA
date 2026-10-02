#!/usr/bin/env python3
"""
Passo 01b -- Converte os .mat do dataset em arquivos .npy compactos.

Alternativa ao passo 01 (que le CSV). Os autores do dataset distribuem os
dados de vibracao em MAT binario -- o CSV e uma exportacao que ocupa ~6x mais
(9.7 GB contra 1.5 GB). Ler o .mat direto evita essa conversao intermediaria.

Saida IDENTICA a do passo 01, de modo que o passo 02 funciona sem alteracao:
    dados/processado/brutos/<nome>.npy, float32, shape (N, 2) = (x_A, y_A)

Estrutura do .mat (export do Siemens SCADAS):
    Signal.x_values.increment         -> 1/fs
    Signal.x_values.number_of_values  -> N
    Signal.y_values.values            -> (N, 4) = x_A, y_A, x_B, y_B  [g]

Mantem apenas o mancal A: segundo o artigo, TODAS as falhas foram inseridas
junto ao mancal A (rolamento com defeito na carcaca A, desalinhamento movendo
o eixo em A, massa de desbalanceamento no disco mais proximo de A). O mancal B
so ve a vibracao transmitida, bem mais fraca -- conferido nos dados: em
0Nm_BPFO_10 o RMS e 17.1 g em x_A contra 7.1 g em x_B.

    python python/scripts/01b_converter_mat.py
"""
import os
import sys
import time
from pathlib import Path

import numpy as np
import scipy.io

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C

FS_ESPERADA = C.FS_ORIGINAL     # 25600 Hz, conforme o artigo
N_CANAIS    = 4                 # x_A, y_A, x_B, y_B


def le_mat(caminho: Path):
    """Le um .mat do dataset e devolve (sinal (N,2) float32, fs, n_amostras)."""
    d = scipy.io.loadmat(caminho, squeeze_me=True, struct_as_record=False)
    if "Signal" not in d:
        raise ValueError(f"{caminho.name}: nao contem a struct 'Signal'")
    S = d["Signal"]
    fs = 1.0 / S.x_values.increment
    n = int(S.x_values.number_of_values)
    v = np.asarray(S.y_values.values)

    # Validacao contra a especificacao do artigo -- falha alto em vez de
    # produzir silenciosamente um dataset com taxa errada.
    if abs(fs - FS_ESPERADA) > 1.0:
        raise ValueError(f"{caminho.name}: fs={fs:.1f} Hz, esperado {FS_ESPERADA}")
    if v.ndim != 2 or v.shape[1] != N_CANAIS:
        raise ValueError(f"{caminho.name}: shape {v.shape}, esperado (N, {N_CANAIS})")
    if v.shape[0] != n:
        raise ValueError(f"{caminho.name}: {v.shape[0]} amostras, cabecalho diz {n}")

    return v[:, :2].astype(np.float32), fs, n      # so o mancal A


def ok(npy: Path) -> bool:
    """Arquivo ja convertido e integro?"""
    try:
        return np.load(npy, mmap_mode="r").shape[0] > 0
    except Exception:
        return False


def main():
    C.DIR_BRUTOS.mkdir(parents=True, exist_ok=True)
    arquivos = sorted(C.DIR_MAT.glob("*.mat"))
    if not arquivos:
        sys.exit(f"Nenhum .mat em {C.DIR_MAT}")

    total_s = 0.0
    for i, mat in enumerate(arquivos, 1):
        # O proprio dataset traz 5 arquivos grafados 'Unbalalnce'; normaliza
        # para que o nome da classe e os relatorios fiquem consistentes.
        nome = mat.stem.replace("Unbalalnce", "Unbalance")
        npy = C.DIR_BRUTOS / f"{nome}.npy"
        if ok(npy):
            print(f"[{i:2d}/{len(arquivos)}] {nome}: ja convertido")
            total_s += np.load(npy, mmap_mode="r").shape[0] / FS_ESPERADA
            continue

        t = time.time()
        x, fs, n = le_mat(mat)
        tmp = npy.with_suffix(".tmp.npy")
        np.save(tmp, x)
        os.replace(tmp, npy)               # gravacao atomica
        total_s += n / fs
        print(f"[{i:2d}/{len(arquivos)}] {nome}: {n} amostras "
              f"({n / fs:.0f} s) em {time.time() - t:.1f} s", flush=True)

    print(f"\n{len(arquivos)} arquivos, {total_s:.0f} s de sinal "
          f"({total_s/60:.1f} min) em {C.DIR_BRUTOS}")


if __name__ == "__main__":
    main()
