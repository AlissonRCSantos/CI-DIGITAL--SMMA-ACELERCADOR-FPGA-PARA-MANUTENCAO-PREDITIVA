#!/usr/bin/env python3
"""
Passo 05 -- Leva os pesos treinados para o RTL.

    python python/scripts/05_exportar_rtl.py            # usa pesos_16b.npz
    python python/scripts/05_exportar_rtl.py --bits 8   # exporta a versao 8 bits

Gera / atualiza (NADA e editado a mao):
  RTL/cnn/CNN_Weight_ROM.v        -- ROM com os pesos treinados (mesma interface)
  sim/golden/golden_model_cnn.py         -- constantes KER/BIAS/DENSE_W/DENSE_B atualizadas
  quartus/vetores/rom_pesos.hex   -- 116 pesos esperados      (tb_CNN_Weight_ROM)
  quartus/vetores/conv_esperado.hex  -- saidas da convolucao  (tb_CNN_Conv_Layer)
  quartus/vetores/dense_esperado.hex -- features/scores/classe (tb_CNN_Dense_Classifier)
  quartus/vetores/top_imagens.hex    -- espectrogramas REAIS do conjunto de teste
  quartus/vetores/top_esperado.hex   -- saida esperada do CNN_Top para cada um
Os valores esperados sao calculados com o sim/golden/golden_model_cnn.py (modelo
bit-exato original) e conferidos com smma/golden.py.
"""
import sys, re, argparse, importlib
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config as C
from smma import golden as V

N_IMG_POR_CLASSE = 2


def h16(v):
    return f"{int(v) & 0xFFFF:04x}"


def sd(v):
    """literal Verilog de 16 bits com sinal"""
    v = int(v)
    return f"-16'sd{-v}" if v < 0 else f" 16'sd{v}"


def gera_rom(p, bits, acc):
    ker, bias, dw, db = p["ker"], p["bias"], p["dw"], p["db"]
    L = []
    for t in range(9):
        campos = ", ".join(f"{sd(ker[f, t]):>12s}" for f in range(7, -1, -1))
        L.append(f"            4'd{t}: conv_w = {{ {campos} }};")
    conv_case = "\n".join(L)
    bias_str = ", ".join(sd(bias[f]).strip() for f in range(7, -1, -1))
    D = []
    for k in range(4):
        D.append(f"            // ---- Classe {k}: {C.CLASSES[k].upper()} ----")
        for i in range(8):
            a = k * 8 + i
            D.append(f"            5'd{a:<2d}: dense_w = {sd(dw[k, i])};   // feature F{i}")
    dense_case = "\n".join(D)
    DB = "\n".join(f"            2'd{k}: dense_bias = {sd(db[k])};   // {C.CLASSES[k]}" for k in range(4))
    return f"""// ============================================================================
// Module: CNN_Weight_ROM
// Description: Memoria somente-leitura com TODOS os pesos TREINADOS da CNN.
//
//   *** ARQUIVO GERADO AUTOMATICAMENTE -- NAO EDITAR A MAO ***
//   Gerado por: python/scripts/05_exportar_rtl.py
//   Treino    : python/scripts/03_treinar.py (PyTorch, arquitetura identica
//               a deste RTL, pesos de {bits} bits em Q1.15)
//   Dataset   : Jung et al., Data in Brief 48 (2023) -- KAIST, acelerometro
//               x do mancal A, espectrograma 32x32 (FFT 64 pts, 3.2 kHz, 10 ms)
//   Acuracia  : {acc}
//
// ORGANIZACAO DOS PESOS (inalterada)
// ----------------------------------
// A convolucao processa 1 tap por ciclo, mas os 8 FILTROS em PARALELO. Logo,
// no ciclo do tap t, precisamos dos 8 pesos w[filtro][t] SIMULTANEAMENTE.
// Por isso a ROM e organizada "por tap":
//
//     endereco = t (0..8)  ->  palavra de 8 x 16 = 128 bits
//                              {{ w7[t], w6[t], ..., w1[t], w0[t] }}
//     tap t = linha*3 + coluna da janela 3x3
//
// Camada densa: endereco = classe*8 + feature (4 classes x 8 features).
// Classes: 0 = normal, 1 = desbalanceamento, 2 = desalinhamento,
//          3 = desgaste de rolamento (ordem pedida no enunciado, secao 3.5).
//
// Codificacao Q1.15: valor_inteiro = valor_real * 32768, faixa [-1, +0.99997].
// Bloco puramente COMBINACIONAL (ROM assincrona), sintetiza em LUTs.
// ============================================================================

`timescale 1ns / 1ps

module CNN_Weight_ROM #(
    parameter WIDTH        = 16,
    parameter NUM_FILTERS  = 8
)(
    // ---- Porta de leitura dos kernels convolucionais ----
    input  wire [3:0]                        tap_addr,    // 0..8 (tap da janela 3x3)
    output reg  [NUM_FILTERS*WIDTH-1:0]      conv_w,      // 8 pesos (1 por filtro)
    output wire [NUM_FILTERS*WIDTH-1:0]      conv_bias,   // 8 bias (1 por filtro)

    // ---- Porta de leitura da camada densa ----
    input  wire [4:0]                        dense_addr,  // classe*8 + feature
    output reg  signed [WIDTH-1:0]           dense_w,
    input  wire [1:0]                        dense_bias_addr,
    output reg  signed [WIDTH-1:0]           dense_bias
);

    // ========================================================================
    // 1. Kernels convolucionais 3x3 (8 filtros treinados)
    //    Formato da palavra: {{ F7, F6, F5, F4, F3, F2, F1, F0 }}
    // ========================================================================
    always @(*) begin
        case (tap_addr)
{conv_case}
            default: conv_w = {{(NUM_FILTERS*WIDTH){{1'b0}}}};
        endcase
    end

    // Ordem: {{ b7, b6, b5, b4, b3, b2, b1, b0 }}
    assign conv_bias = {{ {bias_str} }};

    // ========================================================================
    // 2. Camada densa (classificador): 4 classes x 8 features
    // ========================================================================
    always @(*) begin
        case (dense_addr)
{dense_case}
            default: dense_w = 16'sd0;
        endcase
    end

    always @(*) begin
        case (dense_bias_addr)
{DB}
            default: dense_bias = 16'sd0;
        endcase
    end

endmodule
"""


def atualiza_golden(path, p):
    s = path.read_text(encoding="utf-8")
    ker = ",\n".join("    [" + ", ".join(f"{int(v):6d}" for v in p["ker"][f]) + f"],  # F{f}" for f in range(8))
    dw = ",\n".join("    [" + ", ".join(f"{int(v):6d}" for v in p["dw"][k]) + f"],  # classe {k} {C.CLASSES[k]}" for k in range(4))
    novo = ("# ---- PESOS TREINADOS (gerados por python/scripts/05_exportar_rtl.py) ----\n"
            "# Kernels: indice = filtro, lista de 9 taps em ordem linha*3+coluna\n"
            f"KER = [\n{ker},\n]\n"
            f"BIAS = [{', '.join(str(int(v)) for v in p['bias'])}]\n\n"
            f"DENSE_W = [\n{dw},\n]\n"
            f"DENSE_B = [{', '.join(str(int(v)) for v in p['db'])}]\n")
    s2, n = re.subn(r"# ---- (Kernels|PESOS TREINADOS).*?DENSE_B = \[[^\]]*\]\n", lambda m: novo, s, flags=re.S)
    if n != 1:
        sys.exit("nao encontrei o bloco de pesos em golden_model_cnn.py")
    path.write_text(s2, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=16)
    a = ap.parse_args()
    arq = C.DIR_RESULT / f"pesos_{a.bits}b.npz"
    if not arq.exists():
        sys.exit(f"{arq} nao existe -- rode o passo 03")
    p = {k: np.asarray(v, np.int64) for k, v in np.load(arq).items()}
    d = np.load(C.DIR_ESPEC / "dataset.npz")
    X, y = d["X_teste"], d["y_teste"].astype(int)
    _, _, pr = V.run(X, p["ker"], p["bias"], p["dw"], p["db"])
    acc = f"{(pr == y).mean() * 100:.1f}% no conjunto de teste ({len(y)} imagens, ponto fixo bit-exato)"

    (C.DIR_RTL / "cnn" / "CNN_Weight_ROM.v").write_text(gera_rom(p, a.bits, acc), encoding="utf-8")
    atualiza_golden(C.DIR_GOLDEN / "golden_model_cnn.py", p)
    sys.path.insert(0, str(C.DIR_GOLDEN))
    G = importlib.import_module("golden_model_cnn"); importlib.reload(G)

    vet = C.DIR_VET; vet.mkdir(exist_ok=True)
    # 1) ROM: 72 conv (filtro, tap) + 8 bias + 32 densa + 4 bias
    rom = list(p["ker"].reshape(-1)) + list(p["bias"]) + list(p["dw"].reshape(-1)) + list(p["db"])
    (vet / "rom_pesos.hex").write_text("\n".join(h16(v) for v in rom) + "\n")

    # 2) Convolucao: mesmas 4 janelas do testbench
    janelas = [[8192] * 9,
               [0, 0, 0, 0, 32767, 0, 0, 0, 0],
               [0, 4096, 8192, 12288, 16384, 20480, 24576, 28672, 32767],
               [-8192] * 9]
    conv = []
    for w in janelas:
        for f in range(8):
            acc_ = (G.BIAS[f] << G.FRAC) + sum(px * k for px, k in zip(w, G.KER[f]))
            conv.append(G.scale(acc_, relu=True))
    (vet / "conv_esperado.hex").write_text("\n".join(h16(v) for v in conv) + "\n")

    # 3) Densa: 3 testes do testbench (features ja conhecidas)
    testes = [[1000, 20000, 3000, 15000, 500, 800, 12000, 9000], [6000] * 8, [0] * 8]
    dense = []
    for fv in testes:
        sc, k = G.dense(fv)
        dense += list(fv) + list(sc) + [k]
    (vet / "dense_esperado.hex").write_text("\n".join(h16(v) for v in dense) + "\n")

    # 4) Sistema: espectrogramas reais do teste, N por classe (sorteio fixo)
    rng = np.random.default_rng(C.SEMENTE)
    idx = np.concatenate([rng.choice(np.where(y == c)[0], N_IMG_POR_CLASSE, replace=False)
                          for c in range(4)])
    imgs, esp = [], []
    for i in idx:
        img = X[i].astype(int).tolist()
        _, _, f, s, k = G.run(img)
        f2, s2, k2 = V.run(X[i:i + 1], p["ker"], p["bias"], p["dw"], p["db"])
        assert f == f2[0].tolist() and s == s2[0].tolist() and k == k2[0], "golden divergente"
        imgs += [v for linha in img for v in linha]
        esp += list(f) + list(s) + [k, y[i]]
    (vet / "top_imagens.hex").write_text("\n".join(h16(v) for v in imgs) + "\n")
    (vet / "top_esperado.hex").write_text("\n".join(h16(v) for v in esp) + "\n")
    origem = [str(d["arquivos"][d["g_teste"][i]]) for i in idx]
    (vet / "top_origem.txt").write_text(
        "Imagens usadas em tb_CNN_Top (ordem):\n" +
        "\n".join(f"{n}: {o} (classe real {C.CLASSES[y[i]]})" for n, (o, i) in enumerate(zip(origem, idx))) + "\n")

    print(f"Pesos de {a.bits} bits exportados. {acc}")
    print("Gerados: RTL/cnn/CNN_Weight_ROM.v, sim/golden/golden_model_cnn.py, quartus/vetores/*.hex")


if __name__ == "__main__":
    main()
