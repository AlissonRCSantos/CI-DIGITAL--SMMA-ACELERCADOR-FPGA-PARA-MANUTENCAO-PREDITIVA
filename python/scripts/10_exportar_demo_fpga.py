#!/usr/bin/env python3
"""
Passo 10 -- Exporta janelas do dataset para a ROM de demonstracao na FPGA.

Motivacao
---------
O enunciado (6.7) exige demonstrar o projeto gravado na placa, "utilizando
sinais de entrada e saida que permitam verificar o processamento". Sem um
acelerometro ligado a FPGA, a forma honesta de fazer isso e embarcar trechos
REAIS do dataset numa ROM e deixar o sistema processa-los.

Por que so janelas de TESTE
---------------------------
As janelas vem exclusivamente da particao de TESTE -- os ultimos 15% de cada
arquivo, que o modelo nunca viu no treino. Demonstrar a placa acertando
janelas de TREINO nao provaria nada: o modelo as memorizou. A particao de
treino continua disponivel no fluxo Python para depuracao, mas nao vai para
a placa.

Selecao
-------
12 janelas = 4 classes x 3 cargas (0, 2 e 4 Nm), escolhidas de forma
DETERMINISTICA (a primeira janela de teste de cada combinacao). Nao ha
escolha a dedo de casos que acertam: a classe prevista pelo modelo e gravada
junto da verdadeira, entao uma eventual classificacao errada fica VISIVEL na
demonstracao. O sistema acerta ~93%, nao 100%, e esconder isso seria
desonesto.

Amostras CRUAS (25,6 kHz), nao decimadas: assim a demonstracao exercita a
cadeia completa, incluindo o FIR anti-aliasing e o decimador.

Saidas:
    quartus/vetores/demo_amostras.hex   amostras Q1.15, janelas concatenadas
    quartus/vetores/demo_rotulos.hex    por janela: {classe verdadeira, prevista}
    quartus/vetores/demo_info.txt       legenda legivel das janelas

    python python/scripts/10_exportar_demo_fpga.py
"""
import sys
from pathlib import Path

import numpy as np
from sklearn.tree import DecisionTreeClassifier

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import features as F
from smma.espectrograma import FUNDO_ESCALA_G

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib import import_module
cadeia_frontend = import_module("06_gerar_features").cadeia_frontend

DIR_FEAT = C.RAIZ / "dados" / "processado" / "features"
DIR_VET = C.DIR_VET
Q = 1 << C.FRAC
CARGAS = ("0Nm", "2Nm", "4Nm")

# um arquivo representativo por (classe, carga) -- severidade intermediaria,
# para nao demonstrar nem o caso mais facil nem o mais dificil
REPRESENTANTE = {
    "normal":           "Normal",
    "desbalanceamento": "Unbalance_1751mg",
    "desalinhamento":   "Misalign_03",
    "rolamento":        "BPFO_10",
}


def main():
    DIR_VET.mkdir(parents=True, exist_ok=True)

    d = np.load(DIR_FEAT / "features.npz", allow_pickle=True)
    clf = DecisionTreeClassifier(max_depth=9, random_state=42,
                                 class_weight="balanced").fit(d["X_treino"],
                                                              d["y_treino"])
    guarda_q = int(C.GUARDA_S * C.FS_ORIGINAL / C.DECIMACAO / C.HOP)

    amostras, rotulos, info = [], [], []
    n_raw = None

    for carga in CARGAS:
        for cls_nome, sufixo in REPRESENTANTE.items():
            nome = f"{carga}_{sufixo}"
            arq = C.DIR_BRUTOS / f"{nome}.npy"
            if not arq.exists():
                sys.exit(f"faltando {arq}; rode o passo 01b")

            x = np.load(arq, mmap_mode="r")[:, C.CANAL].astype(np.float64)
            sinal, mags = cadeia_frontend(x)
            nq = mags.shape[0]

            # mesma particao do passo 06: a 1a janela de TESTE
            i_va = int(nq * (C.FRACAO_TREINO + C.FRACAO_VALID))
            i0 = i_va + guarda_q

            # features -> classe prevista pelo modelo
            feat = np.asarray(F.extrai(sinal, mags, i0, C.NQUADROS))
            prev = int(clf.predict(feat.reshape(1, -1))[0])
            verd = C.classe_do_arquivo(nome)

            # faixa de amostras CRUAS que a FFT dessa janela consome.
            # O FIR do hardware produz a saida decimada m a partir das amostras
            # cruas [m*DECIM .. m*DECIM + NFIR-1]; comecando o stream em
            # a*DECIM, a primeira saida coincide com a amostra decimada 'a'.
            a = i0 * C.HOP
            b = a + (C.NQUADROS - 1) * C.HOP + C.NFFT
            ini_raw = a * C.DECIMACAO
            fim_raw = (b - 1) * C.DECIMACAO + C.NFIR
            bruto = x[ini_raw:fim_raw]
            xq = np.clip(np.round(bruto / FUNDO_ESCALA_G * Q), -Q, Q - 1).astype(np.int64)

            if n_raw is None:
                n_raw = len(xq)
            elif len(xq) != n_raw:
                sys.exit(f"{nome}: {len(xq)} amostras, esperado {n_raw}")

            amostras.append(xq)
            rotulos.append((verd, prev))
            marca = "ok " if verd == prev else "ERRO"
            info.append(f"{len(info):2d}  {nome:<28} verdadeira={C.CLASSES[verd]:<16} "
                        f"prevista={C.CLASSES[prev]:<16} {marca}")
            print(info[-1])

    # ---- grava ----
    plano = np.concatenate(amostras)
    (DIR_VET / "demo_amostras.hex").write_text(
        "\n".join(f"{int(v) & 0xFFFF:04X}" for v in plano) + "\n")
    (DIR_VET / "demo_rotulos.hex").write_text(
        "\n".join(f"{(v << 2) | p:01X}" for v, p in rotulos) + "\n")

    cab = [f"ROM de demonstracao do SMMA -- {len(amostras)} janelas de TESTE",
           f"amostras por janela : {n_raw} (cruas, 25.6 kHz, Q1.15)",
           f"duracao por janela  : {n_raw/C.FS_ORIGINAL*1000:.0f} ms",
           f"memoria total       : {len(plano)*2/1024:.1f} kB em 16 bits",
           f"rotulos             : bits[3:2]=verdadeira  bits[1:0]=prevista",
           ""]
    (DIR_VET / "demo_info.txt").write_text("\n".join(cab + info) + "\n")

    acertos = sum(1 for v, p in rotulos if v == p)
    print(f"\n{len(amostras)} janelas, {n_raw} amostras cada "
          f"({n_raw/C.FS_ORIGINAL*1000:.0f} ms)")
    rom_kb = len(plano) * 2 / 1024          # 16 bits por amostra no hardware
    print(f"ROM: {rom_kb:.1f} kB em 16 bits ({rom_kb/384*100:.0f}% da M10K da Cyclone V)")
    print(f"o modelo acerta {acertos}/{len(rotulos)} destas janelas")
    print(f"gravado em {DIR_VET}")


if __name__ == "__main__":
    main()
