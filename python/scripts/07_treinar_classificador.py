#!/usr/bin/env python3
"""
Passo 07 -- Treina o classificador numerico (PBL 3.5) e escolhe a arquitetura.

Compara as duas opcoes pedidas -- ARVORE DE DECISAO e SVM com kernel RBF --
em acuracia E em custo de hardware, porque o enunciado exige justificar por
que o modelo escolhido e adequado para FPGA (secao 3.5).

Depois quantiza o vencedor para Q1.15 e exporta a ROM que o Verilog le.

Saida:
    python/resultados/classificador.npz   (modelo quantizado)
    RTL/vetores/arvore.hex                (ROM de nos, para o Verilog)
    RTL/vetores/clf_teste.hex             (vetores de teste do testbench)
    python/resultados/relatorio_clf.md

    python python/scripts/07_treinar_classificador.py
"""
import sys
from pathlib import Path

import numpy as np
from sklearn.tree import DecisionTreeClassifier
from sklearn.svm import SVC
from sklearn.metrics import accuracy_score, balanced_accuracy_score, confusion_matrix

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import features as F

DIR_FEAT = C.RAIZ / "dados" / "processado" / "features"
Q = 1 << C.FRAC
SEMENTE = 42


# ---------------------------------------------------------------------------
# Custo de hardware (o criterio que decide, junto com a acuracia)
# ---------------------------------------------------------------------------
def custo_arvore(clf):
    """Arvore: so comparacoes. Latencia = profundidade."""
    n_nos = clf.tree_.node_count
    prof = clf.get_depth()
    return dict(dsp=0, mult_por_decisao=0, memoria_bits=n_nos * 32,
                latencia_ciclos=prof, detalhe=f"{n_nos} nos, profundidade {prof}")


def custo_svm(clf):
    """SVM-RBF: 12 multiplicacoes por vetor de suporte + exp()."""
    n_sv = int(clf.n_support_.sum())
    mults = n_sv * F.N_FEATURES
    return dict(dsp="muitos", mult_por_decisao=mults,
                memoria_bits=n_sv * F.N_FEATURES * 16,
                latencia_ciclos=mults,   # com 1 multiplicador compartilhado
                detalhe=f"{n_sv} vetores de suporte x {F.N_FEATURES} features")


def avalia(nome, yv, yp):
    return dict(nome=nome, acc=accuracy_score(yv, yp),
                bal=balanced_accuracy_score(yv, yp))


def main():
    d = np.load(DIR_FEAT / "features.npz", allow_pickle=True)
    Xtr, ytr = d["X_treino"], d["y_treino"]
    Xva, yva = d["X_valid"], d["y_valid"]
    Xte, yte = d["X_teste"], d["y_teste"]
    gte, arquivos = d["g_teste"], d["arquivos"]
    print(f"treino={len(ytr)}  valid={len(yva)}  teste={len(yte)}  "
          f"({F.N_FEATURES} features)\n")

    linhas = ["# Classificador numerico do SMMA (PBL 3.5)\n",
              f"Entradas: {F.N_FEATURES} caracteristicas "
              f"(FFT + LMS + estimacao matricial).  ",
              f"Saidas: 4 classes {C.CLASSES}.  ",
              f"Conjunto de teste: {len(yte)} janelas -- as MESMAS da CNN.\n"]

    # ---------------- Arvore de decisao: varre a profundidade --------------
    print("== ARVORE DE DECISAO ==")
    linhas += ["\n## Arvore de decisao: profundidade x acuracia\n",
               "| Profundidade | Nos | Acuracia (valid) | Balanceada (valid) |",
               "|---|---|---|---|"]
    melhor, melhor_bal = None, -1
    for prof in range(3, 13):
        clf = DecisionTreeClassifier(max_depth=prof, random_state=SEMENTE,
                                     class_weight="balanced")
        clf.fit(Xtr, ytr)
        r = avalia(f"arvore d={prof}", yva, clf.predict(Xva))
        print(f"  profundidade {prof:2d}: nos={clf.tree_.node_count:4d} "
              f"valid acc={r['acc']:.4f} bal={r['bal']:.4f}")
        linhas.append(f"| {prof} | {clf.tree_.node_count} | "
                      f"{r['acc']:.4f} | {r['bal']:.4f} |")
        if r["bal"] > melhor_bal:
            melhor_bal, melhor = r["bal"], clf
    arvore = melhor
    print(f"  -> escolhida: profundidade {arvore.get_depth()}, "
          f"{arvore.tree_.node_count} nos")

    # ---------------- SVM-RBF ---------------------------------------------
    print("\n== SVM (kernel RBF) ==")
    # padroniza: o RBF e sensivel a escala das features
    mu, sd = Xtr.mean(0), Xtr.std(0) + 1e-12
    svm = SVC(kernel="rbf", C=10.0, gamma="scale",
              class_weight="balanced", random_state=SEMENTE, cache_size=1000)
    svm.fit((Xtr - mu) / sd, ytr)
    r_svm_va = avalia("svm", yva, svm.predict((Xva - mu) / sd))
    print(f"  vetores de suporte: {int(svm.n_support_.sum())}  "
          f"valid acc={r_svm_va['acc']:.4f} bal={r_svm_va['bal']:.4f}")

    # ---------------- Comparacao: acuracia x custo -------------------------
    ca, cs = custo_arvore(arvore), custo_svm(svm)
    r_arv_te = avalia("arvore", yte, arvore.predict(Xte))
    r_svm_te = avalia("svm", yte, svm.predict((Xte - mu) / sd))

    print("\n== COMPARACAO (conjunto de teste) ==")
    print(f"{'modelo':<10}{'acc':>8}{'balanceada':>12}{'mult/decisao':>14}"
          f"{'latencia':>10}{'memoria':>10}")
    print("-" * 66)
    print(f"{'arvore':<10}{r_arv_te['acc']:8.4f}{r_arv_te['bal']:12.4f}"
          f"{ca['mult_por_decisao']:14d}{ca['latencia_ciclos']:10d}"
          f"{ca['memoria_bits']//8:9d}B")
    print(f"{'svm-rbf':<10}{r_svm_te['acc']:8.4f}{r_svm_te['bal']:12.4f}"
          f"{cs['mult_por_decisao']:14d}{cs['latencia_ciclos']:10d}"
          f"{cs['memoria_bits']//8:9d}B")

    linhas += ["\n## Arvore x SVM-RBF (conjunto de teste)\n",
               "| Modelo | Acuracia | Balanceada | Mult/decisao | Latencia (ciclos) | Memoria |",
               "|---|---|---|---|---|---|",
               f"| Arvore de decisao | {r_arv_te['acc']:.4f} | {r_arv_te['bal']:.4f} "
               f"| **{ca['mult_por_decisao']}** | {ca['latencia_ciclos']} | {ca['memoria_bits']//8} B |",
               f"| SVM-RBF | {r_svm_te['acc']:.4f} | {r_svm_te['bal']:.4f} "
               f"| {cs['mult_por_decisao']} | ~{cs['latencia_ciclos']} | {cs['memoria_bits']//8} B |",
               f"\n- Arvore: {ca['detalhe']}",
               f"- SVM: {cs['detalhe']}"]

    np.savez(C.DIR_RESULT / "comparacao_clf.npz",
             arv_acc=r_arv_te["acc"], svm_acc=r_svm_te["acc"])
    Path(C.DIR_RESULT / "relatorio_clf.md").write_text("\n".join(linhas) + "\n")
    print(f"\nrelatorio parcial em {C.DIR_RESULT/'relatorio_clf.md'}")

    # guarda a arvore para o passo de quantizacao/exportacao
    np.savez(C.DIR_RESULT / "arvore_float.npz",
             feature=arvore.tree_.feature, threshold=arvore.tree_.threshold,
             left=arvore.tree_.children_left, right=arvore.tree_.children_right,
             value=arvore.tree_.value)
    print(f"arvore salva em {C.DIR_RESULT/'arvore_float.npz'}")


if __name__ == "__main__":
    main()
