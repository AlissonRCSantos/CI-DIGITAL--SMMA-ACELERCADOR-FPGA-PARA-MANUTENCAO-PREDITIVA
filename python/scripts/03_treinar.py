#!/usr/bin/env python3
"""
Passo 03 -- Treina a CNN (mesma arquitetura do RTL) com os espectrogramas.

    python python/scripts/03_treinar.py            # pesos de 16 bits (padrao)
    python python/scripts/03_treinar.py --bits 8   # treino ciente de 8 bits
    python python/scripts/03_treinar.py --bits 4

Saidas em python/resultados/:
    modelo_<bits>b.pt        -- pesos em float (PyTorch)
    pesos_<bits>b.npz        -- pesos INTEIROS Q1.15 prontos para o hardware
    treino_<bits>b.log       -- evolucao por epoca
O melhor modelo e escolhido pela acuracia BALANCEADA na validacao
(media do acerto de cada classe -- as classes tem tamanhos diferentes).
"""
import sys, argparse, time
from pathlib import Path
import numpy as np
import torch
import torch.nn.functional as F
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma.modelo import CNN_SMMA
from smma import golden


def carrega(d, k):
    X = torch.tensor(d[f"X_{k}"].astype(np.float32) / 32768.0).unsqueeze(1)
    return X, torch.tensor(d[f"y_{k}"].astype(np.int64))


def acc_balanceada(pred, y, n=4):
    return float(np.mean([(pred[y == c] == c).mean() for c in range(n)]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=16)
    ap.add_argument("--epocas", type=int, default=60)
    ap.add_argument("--lr", type=float, default=0.01)
    ap.add_argument("--semente", type=int, default=C.SEMENTE)
    ap.add_argument("--temperatura", type=float, default=32.0,
                    help="os scores ficam em [-1,1); multiplica-se antes do softmax")
    a = ap.parse_args()
    torch.manual_seed(a.semente); np.random.seed(a.semente)
    C.DIR_RESULT.mkdir(parents=True, exist_ok=True)

    d = np.load(C.DIR_ESPEC / "dataset.npz")
    Xtr, ytr = carrega(d, "treino")
    Xva_int, yva = d["X_valid"], d["y_valid"]
    # peso de cada classe na perda = inverso da frequencia (classes desbalanceadas)
    freq = torch.bincount(ytr, minlength=4).float()
    peso_cls = freq.sum() / (4 * freq)

    net = CNN_SMMA(bits=a.bits)
    opt = torch.optim.Adam(net.parameters(), lr=a.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, a.epocas)
    log = open(C.DIR_RESULT / f"treino_{a.bits}b.log", "w")
    melhor, t0 = -1, time.time()
    for ep in range(1, a.epocas + 1):
        net.train()
        perm = torch.randperm(len(ytr))
        perda = 0.0
        for i in range(0, len(perm), 128):
            idx = perm[i:i + 128]
            s = net(Xtr[idx])
            loss = F.cross_entropy(s * a.temperatura, ytr[idx], weight=peso_cls)
            opt.zero_grad(); loss.backward(); opt.step(); net.limita()
            perda += loss.item() * len(idx)
        sched.step()
        # validacao com o modelo BIT-EXATO (o que o FPGA calcularia)
        p = net.pesos_inteiros()
        _, _, pred = golden.run(Xva_int, p["ker"], p["bias"], p["dw"], p["db"])
        acc = acc_balanceada(pred, yva)
        linha = f"epoca {ep:3d}  perda={perda / len(ytr):.4f}  val_bal(ponto fixo)={acc:.4f}"
        print(linha, flush=True); log.write(linha + "\n")
        if acc > melhor:
            melhor = acc
            torch.save(net.state_dict(), C.DIR_RESULT / f"modelo_{a.bits}b.pt")
            np.savez(C.DIR_RESULT / f"pesos_{a.bits}b.npz", **p)
    msg = f"melhor acuracia balanceada de validacao: {melhor:.4f}  ({time.time() - t0:.0f} s)"
    print(msg); log.write(msg + "\n")


if __name__ == "__main__":
    main()
