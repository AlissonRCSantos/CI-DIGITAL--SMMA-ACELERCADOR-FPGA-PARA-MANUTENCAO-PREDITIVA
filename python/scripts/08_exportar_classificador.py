#!/usr/bin/env python3
"""
Passo 08 -- Quantiza a arvore de decisao e exporta a ROM lida pelo Verilog.

Escolha de arquitetura (justificativa pedida no enunciado 3.5)
-------------------------------------------------------------
O passo 07 mede arvore x SVM-RBF nas MESMAS janelas de teste. A SVM acerta
alguns pontos a mais, mas custa ~22 mil multiplicacoes e ~44 kB de vetores de
suporte POR DECISAO, contra ZERO multiplicacoes e ~0.6 kB da arvore. Como o
enunciado lista "quantidade limitada de multiplicadores DSP" entre as
restricoes (secao 5) -- e a CNN ja consome 8 DSPs e a FFT outros 4 -- a
arvore e a escolha correta para FPGA.

Codificacao da ROM (32 bits por no)
-----------------------------------
A arvore do sklearn e construida em profundidade, o que garante
children_left[i] == i+1 para todo no interno (verificado em tempo de
execucao). So o filho DIREITO precisa ser guardado:

    bit  31     : 1 = folha
    folha  -> bits [1:0]   classe (0..3)
    interno-> bits [30:27] indice da feature (0..11)
              bits [26:11] limiar em Q1.15 (16 bits, complemento de dois)
              bits [10:3]  indice do filho direito (8 bits)

Saidas:
    RTL/vetores/arvore.hex       ROM de nos
    RTL/vetores/clf_teste.hex    vetores de teste (features + classe esperada)
    python/resultados/relatorio_clf.md   (apendido)

    python python/scripts/08_exportar_classificador.py
"""
import sys
from pathlib import Path

import numpy as np
from sklearn.tree import DecisionTreeClassifier
from sklearn.metrics import accuracy_score, balanced_accuracy_score, confusion_matrix

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import features as F

DIR_FEAT = C.RAIZ / "dados" / "processado" / "features"
DIR_VET = C.DIR_RTL / "vetores"
Q = 1 << C.FRAC
SEMENTE = 42
PROFUNDIDADE = 9          # escolhida no passo 07 (melhor acuracia balanceada)
N_TESTE_TB = 64           # vetores gravados para o testbench


def q15(v):
    return int(np.clip(np.round(v * Q), -Q, Q - 1))


def percorre(nos, x_q):
    """Inferencia bit-exata com a mesma aritmetica do Verilog (so inteiros)."""
    i = 0
    while True:
        folha, feat, limiar, dir_ = nos[i]
        if folha:
            return limiar          # no caso de folha, guardamos a classe aqui
        i = (i + 1) if x_q[feat] <= limiar else dir_


def main():
    d = np.load(DIR_FEAT / "features.npz", allow_pickle=True)
    Xtr, ytr = d["X_treino"], d["y_treino"]
    Xte, yte = d["X_teste"], d["y_teste"]
    gte, arquivos = d["g_teste"], d["arquivos"]

    clf = DecisionTreeClassifier(max_depth=PROFUNDIDADE, random_state=SEMENTE,
                                 class_weight="balanced").fit(Xtr, ytr)
    T = clf.tree_
    n_nos = T.node_count
    internos = [i for i in range(n_nos) if T.children_left[i] != -1]

    # A codificacao compacta depende desta propriedade; checa em vez de supor.
    assert all(T.children_left[i] == i + 1 for i in internos), \
        "layout inesperado da arvore: filho esquerdo nao e o no seguinte"
    assert n_nos <= 256, f"{n_nos} nos nao cabem em 8 bits de indice"
    assert F.N_FEATURES <= 16, "indice de feature nao cabe em 4 bits"

    # ---- tabela de nos quantizada ----
    nos = []
    for i in range(n_nos):
        if T.children_left[i] == -1:                 # folha
            classe = int(np.argmax(T.value[i][0]))
            nos.append((1, 0, classe, 0))
        else:
            nos.append((0, int(T.feature[i]), q15(T.threshold[i]),
                        int(T.children_right[i])))

    # ---- acuracia: float (sklearn) x inteiro quantizado (= FPGA) ----
    Xte_q = np.clip(np.round(Xte * Q), -Q, Q - 1).astype(np.int32)
    yp_float = clf.predict(Xte)
    yp_quant = np.array([percorre(nos, x) for x in Xte_q])

    acc_f, bal_f = accuracy_score(yte, yp_float), balanced_accuracy_score(yte, yp_float)
    acc_q, bal_q = accuracy_score(yte, yp_quant), balanced_accuracy_score(yte, yp_quant)
    discord = float(np.mean(yp_float != yp_quant))

    print(f"nos={n_nos} (internos={len(internos)}, folhas={n_nos-len(internos)}) "
          f"profundidade={clf.get_depth()}")
    print(f"float    : acc={acc_f:.4f}  balanceada={bal_f:.4f}")
    print(f"Q1.15    : acc={acc_q:.4f}  balanceada={bal_q:.4f}")
    print(f"discordancia float x ponto fixo: {discord*100:.3f}% das janelas")

    print("\nacerto por carga:")
    por_carga = {}
    for carga in ("0Nm", "2Nm", "4Nm"):
        m = np.array([arquivos[g].startswith(carga) for g in gte])
        a, b = accuracy_score(yte[m], yp_quant[m]), balanced_accuracy_score(yte[m], yp_quant[m])
        por_carga[carga] = (a, b)
        print(f"   {carga}: acc={a:.4f}  balanceada={b:.4f}")

    cm = confusion_matrix(yte, yp_quant)

    # ---- ROM de nos ----
    DIR_VET.mkdir(parents=True, exist_ok=True)
    linhas = []
    for folha, feat, val, dir_ in nos:
        if folha:
            p = (1 << 31) | (val & 0x3)
        else:
            p = ((feat & 0xF) << 27) | ((val & 0xFFFF) << 11) | ((dir_ & 0xFF) << 3)
        linhas.append(f"{p & 0xFFFFFFFF:08X}")
    (DIR_VET / "arvore.hex").write_text("\n".join(linhas) + "\n")

    # ---- vetores de teste para o testbench ----
    rng = np.random.default_rng(SEMENTE)
    idx = rng.choice(len(yte), size=min(N_TESTE_TB, len(yte)), replace=False)
    tb = []
    for i in idx:
        tb += [f"{int(v) & 0xFFFF:04X}" for v in Xte_q[i]]
        tb.append(f"{int(yp_quant[i]):04X}")
    (DIR_VET / "clf_teste.hex").write_text("\n".join(tb) + "\n")

    print(f"\nROM:     {DIR_VET/'arvore.hex'}  ({n_nos} nos, {n_nos*4} bytes)")
    print(f"vetores: {DIR_VET/'clf_teste.hex'}  ({len(idx)} casos)")

    # ---- relatorio ----
    rel = C.DIR_RESULT / "relatorio_clf.md"
    txt = rel.read_text() if rel.exists() else "# Classificador numerico do SMMA\n"
    txt += f"""
## Modelo escolhido: arvore de decisao

Profundidade {clf.get_depth()}, {n_nos} nos ({len(internos)} internos,
{n_nos-len(internos)} folhas), {n_nos*4} bytes de ROM.

| | Acuracia | Balanceada |
|---|---|---|
| float (sklearn) | {acc_f:.4f} | {bal_f:.4f} |
| Q1.15 (= FPGA) | {acc_q:.4f} | {bal_q:.4f} |

Float e ponto fixo discordam em {discord*100:.3f}% das janelas.

### Acerto por carga (comparado a CNN nas MESMAS janelas)

| Carga | Arvore acc | Arvore bal | CNN acc | CNN bal |
|---|---|---|---|---|
| 0 Nm | {por_carga['0Nm'][0]:.4f} | {por_carga['0Nm'][1]:.4f} | 0.8930 | 0.8940 |
| 2 Nm | {por_carga['2Nm'][0]:.4f} | {por_carga['2Nm'][1]:.4f} | 0.8560 | 0.8450 |
| 4 Nm | {por_carga['4Nm'][0]:.4f} | {por_carga['4Nm'][1]:.4f} | 0.7380 | 0.6490 |

### Matriz de confusao (Q1.15)

| real \\ predito | {' | '.join(C.CLASSES)} | acerto |
|---|---|---|---|---|---|
"""
    for i, nome in enumerate(C.CLASSES):
        ac = cm[i, i] / cm[i].sum()
        txt += f"| **{nome}** | " + " | ".join(str(x) for x in cm[i]) + f" | {ac*100:.1f}% |\n"
    txt += f"""
### Recursos

| | Arvore |
|---|---|
| Multiplicadores (DSP) | **0** -- so comparacoes |
| Memoria | {n_nos*4} B (ROM de nos) |
| Latencia | 12 ciclos de carga + 2 por nivel; medido 21 ciclos (420 ns @ 50 MHz) |
| Entradas | {F.N_FEATURES} features Q1.15 |
| Saidas | 2 bits (classe) + valid |
"""
    rel.write_text(txt)
    print(f"relatorio: {rel}")


if __name__ == "__main__":
    main()
