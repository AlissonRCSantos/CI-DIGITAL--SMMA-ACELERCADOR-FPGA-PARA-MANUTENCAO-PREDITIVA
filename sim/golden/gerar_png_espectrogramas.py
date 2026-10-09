#!/usr/bin/env python3
"""
gerar_png_espectrogramas.py -- Figuras dos espectrogramas usados no tb_CNN_Top.

Le:
  vetores/top_imagens.hex       pixels das 8 imagens (os mesmos enviados ao hardware)
  vetores/top_esperado.hex      resposta esperada (golden model) + classe real
  vetores/top_origem.txt        arquivo do dataset de onde veio cada imagem
  sim_out/top_saida_hw.txt      resposta do HARDWARE gravada pelo tb_CNN_Top
                                (se nao existir, usa so a resposta esperada)
Gera, em espectrogramas_teste/:
  imagem_<n>_<origem>.png       uma figura por imagem: espectrograma + scores
  painel_todas.png              as 8 imagens lado a lado

Uso (de qualquer pasta):   python sim/golden/gerar_png_espectrogramas.py
Le os vetores de quartus/vetores/ e a saida do hardware gravada pelo tb_CNN_Top
(top_saida_hw.txt, procurado em quartus/ -- onde o ModelSim/Xcelium roda -- e
aqui mesmo).
Precisa de numpy e matplotlib  (pip install numpy matplotlib).
"""
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.normpath(os.path.join(AQUI, "..", ".."))
VET = os.path.join(RAIZ, "quartus", "vetores")
SAIDA = os.path.join(AQUI, "espectrogramas_teste")
CLASSES = ["normal", "desbalanceamento", "desalinhamento", "rolamento"]
N_IMG, NPIX, NESP = 8, 1024, 14
BIN_HZ, QUADRO_MS = 50, 10          # 50 Hz por bin, 10 ms por FFT


def le_hex(nome):
    vals = []
    with open(os.path.join(VET, nome)) as f:
        for linha in f:
            linha = linha.strip()
            if linha:
                v = int(linha, 16)
                vals.append(v - 65536 if v > 32767 else v)
    return vals


def le_origem():
    origem = {}
    caminho = os.path.join(VET, "top_origem.txt")
    if os.path.exists(caminho):
        for linha in open(caminho, encoding="utf-8"):
            m = re.match(r"(\d+):\s*(\S+)", linha)
            if m:
                origem[int(m.group(1))] = m.group(2)
    return origem


def le_saida_hw():
    """Resposta do hardware gravada pelo testbench (ou None)."""
    for caminho in (os.path.join(RAIZ, "quartus", "sim_out", "top_saida_hw.txt"),
                    os.path.join(RAIZ, "quartus", "top_saida_hw.txt"),
                    os.path.join(AQUI, "top_saida_hw.txt")):
        if os.path.exists(caminho):
            hw = {}
            for linha in open(caminho):
                if linha.startswith("#") or not linha.strip():
                    continue
                v = [int(x) for x in linha.split()]
                hw[v[0]] = {"classe": v[1], "scores": v[2:6], "features": v[6:14], "ciclos": v[14]}
            return hw, caminho
    return None, None


def main():
    try:
        import numpy as np
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("[PNG] precisa de numpy e matplotlib:  pip install numpy matplotlib")

    pix = np.array(le_hex("top_imagens.hex")).reshape(N_IMG, 32, 32)   # (imagem, bin, quadro)
    esp = np.array(le_hex("top_esperado.hex")).reshape(N_IMG, NESP)
    origem = le_origem()
    hw, arq_hw = le_saida_hw()
    os.makedirs(SAIDA, exist_ok=True)

    vmin, vmax = pix.min(), pix.max()                 # mesma escala de cor em todas
    extent = [0, 32 * QUADRO_MS, 0, 32 * BIN_HZ]      # eixo x em ms, eixo y em Hz
    infos = []
    for n in range(N_IMG):
        real = int(esp[n, 13])
        if hw is not None and n in hw:
            pred, scores, fonte = hw[n]["classe"], hw[n]["scores"], "hardware"
        else:
            pred, scores, fonte = int(esp[n, 12]), list(esp[n, 8:12]), "golden (sem simulacao)"
        ok = pred == real
        nome_orig = origem.get(n, f"imagem{n}")
        infos.append((n, nome_orig, real, pred, ok))

        fig, (ax, axs) = plt.subplots(1, 2, figsize=(9.5, 4.2),
                                      gridspec_kw={"width_ratios": [2.2, 1]})
        im = ax.imshow(pix[n], origin="lower", aspect="auto", cmap="magma",
                       vmin=vmin, vmax=vmax, extent=extent)
        ax.set_xlabel("tempo (ms) - 32 FFTs de 10 ms")
        ax.set_ylabel("frequencia (Hz) - 32 bins de 50 Hz")
        ax.axhline(BIN_HZ * 1.5, color="white", lw=0.6, ls=":", alpha=0.7)
        ax.text(2, BIN_HZ * 1.5 + 8, "bin 1 = rotacao (50 Hz)", color="white", fontsize=7, alpha=0.8)
        fig.colorbar(im, ax=ax, label="pixel Q1.15 (log2 |X|)")
        ax.set_title(f"Imagem {n} - {nome_orig}\nreal: {CLASSES[real]}", fontsize=10)

        cores = ["#2e7d32" if (k == pred and ok) else "#c62828" if k == pred else "#9e9e9e"
                 for k in range(4)]
        axs.barh(range(4), scores, color=cores)
        axs.set_yticks(range(4), CLASSES, fontsize=8)
        axs.invert_yaxis()
        axs.axvline(0, color="black", lw=0.6)
        axs.set_xlabel("score (Q1.15)")
        axs.set_title(f"saida do {fonte}\npredito: {CLASSES[pred]} - "
                      f"{'ACERTOU' if ok else 'ERROU'}",
                      fontsize=9, color="#2e7d32" if ok else "#c62828")
        fig.tight_layout()
        arq = os.path.join(SAIDA, f"imagem_{n}_{nome_orig}.png")
        fig.savefig(arq, dpi=120)
        plt.close(fig)

    # painel com as 8 imagens
    fig, axes = plt.subplots(2, 4, figsize=(15, 7.2))
    for (n, nome_orig, real, pred, ok), ax in zip(infos, axes.flat):
        ax.imshow(pix[n], origin="lower", aspect="auto", cmap="magma",
                  vmin=vmin, vmax=vmax, extent=extent)
        ax.set_title(f"{n}: {nome_orig}\nreal {CLASSES[real]} | hw {CLASSES[pred]}",
                     fontsize=8.5, color="#2e7d32" if ok else "#c62828")
        ax.set_xlabel("ms", fontsize=7); ax.set_ylabel("Hz", fontsize=7)
        ax.tick_params(labelsize=7)
    acertos = sum(i[4] for i in infos)
    fig.suptitle(f"Espectrogramas do tb_CNN_Top - {acertos}/{N_IMG} diagnosticos corretos "
                 f"(verde = acertou, vermelho = errou)", fontsize=11)
    fig.tight_layout()
    fig.savefig(os.path.join(SAIDA, "painel_todas.png"), dpi=110)
    plt.close(fig)

    print(f"[PNG] {N_IMG} figuras + painel_todas.png gerados em {SAIDA}")
    print(f"[PNG] resposta usada: {arq_hw if arq_hw else 'golden model (rode o tb_CNN_Top para usar o hardware)'}")


if __name__ == "__main__":
    main()
