#!/usr/bin/env python3
"""
Passo 04 -- Avalia os modelos treinados no conjunto de TESTE.

Para cada modelo treinado (16, 8 e 4 bits) calcula:
  * acuracia do modelo em FLOAT (PyTorch, sem quantizacao)
  * acuracia BIT-EXATA em ponto fixo (smma/golden.py = o que o FPGA calcula)
  * quantizacao pos-treino (PTQ): pega o modelo de 16 bits e so arredonda os
    pesos para 8 e 4 bits, sem retreinar -- para comparar com o treino ciente
    da quantizacao (QAT)
  * matriz de confusao, acerto por arquivo (severidade/carga) e por carga

Gera python/resultados/relatorio.md (+ matriz_confusao.png se houver matplotlib).

    python python/scripts/04_avaliar_ponto_fixo.py
"""
import sys
from pathlib import Path
import numpy as np
import torch
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma.modelo import CNN_SMMA
from smma import golden


def bal(pred, y):
    return float(np.mean([(pred[y == c] == c).mean() for c in range(4)]))


def confusao(y, p):
    M = np.zeros((4, 4), int)
    np.add.at(M, (y, p), 1)
    return M


def main():
    d = np.load(C.DIR_ESPEC / "dataset.npz")
    X, y, g, arq = d["X_teste"], d["y_teste"].astype(int), d["g_teste"], d["arquivos"]
    Xf = torch.tensor(X.astype(np.float32) / 32768.0).unsqueeze(1)
    R = C.DIR_RESULT
    linhas = ["# Resultado do treinamento da CNN do SMMA\n",
              f"Conjunto de TESTE: {len(y)} espectrogramas 32x32 (os ultimos 15% de cada "
              "arquivo, nunca vistos no treino).  ",
              "Acuracia balanceada = media do acerto de cada classe.\n",
              "## Float x ponto fixo x numero de bits\n",
              "| Pesos | Treino | Acuracia float | Acuracia ponto fixo (bit-exata, = FPGA) | Balanceada ponto fixo |",
              "|---|---|---|---|---|"]
    principal = None
    for bits in (16, 8, 4):
        pt = R / f"modelo_{bits}b.pt"
        if not pt.exists():
            continue
        net = CNN_SMMA(bits=32); net.load_state_dict(torch.load(pt)); net.eval()
        with torch.no_grad():
            pf = net(Xf).argmax(1).numpy()
        casos = [("QAT (treino ciente)", bits)]
        if bits == 16:
            casos += [("PTQ (so arredonda)", 8), ("PTQ (so arredonda)", 4)]
        for nome, b in casos:
            nq = CNN_SMMA(bits=b); nq.load_state_dict(torch.load(pt))
            p = nq.pesos_inteiros()
            _, _, pq = golden.run(X, p["ker"], p["bias"], p["dw"], p["db"])
            acc_f = f"{(pf == y).mean():.4f}" if nome.startswith("QAT") else "-"
            linhas.append(f"| {b} bits | {nome} | {acc_f} | {(pq == y).mean():.4f} | {bal(pq, y):.4f} |")
            if bits == 16 and b == 16:
                principal = pq
                acc_float16 = (pf == y).mean()
                dif = (pf != pq).mean()
    if principal is None:
        sys.exit("Rode antes o passo 03 (03_treinar.py)")
    pq = principal
    linhas += ["", f"Modelo de 16 bits: float e ponto fixo discordam em {dif * 100:.2f}% das imagens.\n",
               "## Matriz de confusao (16 bits, ponto fixo)\n",
               "| real \\ predito | " + " | ".join(C.CLASSES) + " | acerto |",
               "|---|---|---|---|---|---|"]
    M = confusao(y, pq)
    for c in range(4):
        linhas.append(f"| **{C.CLASSES[c]}** | " + " | ".join(str(v) for v in M[c]) +
                      f" | {M[c, c] / M[c].sum() * 100:.1f}% |")
    linhas += ["", "## Acerto por arquivo (condicao / severidade / carga)\n",
               "| Arquivo | Classe | Imagens | Acerto |", "|---|---|---|---|"]
    for gi in np.unique(g):
        m = g == gi
        linhas.append(f"| {arq[gi]} | {C.CLASSES[y[m][0]]} | {m.sum()} | {(pq[m] == y[m]).mean() * 100:.0f}% |")
    linhas += ["", "## Acerto por carga\n", "| Carga | Acerto | Balanceada |", "|---|---|---|"]
    carga = np.array([arq[i][:3] for i in g])
    for L in ("0Nm", "2Nm", "4Nm"):
        m = carga == L
        linhas.append(f"| {L} | {(pq[m] == y[m]).mean() * 100:.1f}% | {bal(pq[m], y[m]) * 100:.1f}% |")
    txt = "\n".join(linhas) + "\n"
    (R / "relatorio.md").write_text(txt, encoding="utf-8")
    print(txt)
    try:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        Mn = M / M.sum(1, keepdims=True)
        fig, ax = plt.subplots(figsize=(5.2, 4.4))
        ax.imshow(Mn, cmap="Blues", vmin=0, vmax=1)
        for i in range(4):
            for j in range(4):
                ax.text(j, i, f"{Mn[i, j] * 100:.0f}%\n({M[i, j]})", ha="center", va="center",
                        color="white" if Mn[i, j] > 0.5 else "black", fontsize=8)
        ax.set_xticks(range(4), C.CLASSES, rotation=25, ha="right"); ax.set_yticks(range(4), C.CLASSES)
        ax.set_xlabel("predito"); ax.set_ylabel("real")
        ax.set_title(f"CNN SMMA -- teste, ponto fixo 16 bits\nacuracia {(pq == y).mean() * 100:.1f}%  "
                     f"balanceada {bal(pq, y) * 100:.1f}%", fontsize=9)
        fig.tight_layout(); fig.savefig(R / "matriz_confusao.png", dpi=130)
        print("figura: resultados/matriz_confusao.png")
    except ImportError:
        print("(matplotlib nao instalado: figura nao gerada)")


if __name__ == "__main__":
    main()
