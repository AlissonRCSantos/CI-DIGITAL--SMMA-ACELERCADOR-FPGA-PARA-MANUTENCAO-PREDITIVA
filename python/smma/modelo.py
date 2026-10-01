"""
smma/modelo.py -- A MESMA CNN do RTL, em PyTorch, para o treinamento.

    entrada 32x32x1 (pixel Q1.15 -> float em [0,1))
    Conv 3x3, 8 filtros, stride 1, padding 1, + bias
    saturacao em [-1, 1) e ReLU            (CNN_Conv_Layer + CNN_ReLU)
    MaxPool 2x2 stride 2 -> 16x16x8        (CNN_MaxPool)
    Media global (GAP)  -> 8 features      (CNN_Dense_Classifier, parte 1)
    Densa 8 -> 4 + bias, saturada em [-1,1) (CNN_Dense_Classifier, parte 2)
    argmax                                  -> classe

Restricoes do hardware respeitadas no treino:
  * pesos e bias limitados a [-1, 1 - 2^-15] (faixa do Q1.15);
  * quantizacao dos pesos SIMULADA no forward (fake-quant, com gradiente
    "straight-through"), para n bits = 16, 8 ou 4 -> o que o treino ve e o
    mesmo que o hardware vai calcular.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F


def fake_quant(w: torch.Tensor, bits: int) -> torch.Tensor:
    """Arredonda para Q1.(bits-1) e satura, com gradiente straight-through."""
    if bits >= 24:                      # "float": sem quantizacao
        return w
    q = 2.0 ** (bits - 1)
    wq = torch.clamp(torch.round(w * q), -q, q - 1) / q
    return w + (wq - w).detach()


def relu_sat(y: torch.Tensor, vazamento: float = 0.05) -> torch.Tensor:
    """Forward: EXATAMENTE a saturacao + ReLU do hardware (clamp em [0, 1]).
    Backward: deixa passar um gradiente pequeno (vazamento) onde a saida foi
    cortada, para que filtros "mortos" (sempre <= 0) possam voltar a aprender.
    Nao altera em nada o que o hardware calcula."""
    exato = torch.clamp(y, 0.0, 1.0)
    vazado = torch.where((y < 0) | (y > 1), vazamento * y, y)
    return vazado + (exato - vazado).detach()


class CNN_SMMA(nn.Module):
    def __init__(self, bits: int = 16, n_filtros: int = 8, n_classes: int = 4):
        super().__init__()
        self.bits = bits
        self.conv = nn.Conv2d(1, n_filtros, 3, stride=1, padding=1)
        self.dense = nn.Linear(n_filtros, n_classes)
        with torch.no_grad():
            # pesos pequenos e bias POSITIVO: todas as ReLUs comecam ativas
            # (evita filtros "mortos", que dariam feature sempre zero)
            self.conv.weight.uniform_(-0.15, 0.15); self.conv.bias.fill_(0.05)
            self.dense.weight.uniform_(-0.5, 0.5); self.dense.bias.zero_()

    def limita(self):
        """Mantem os parametros dentro da faixa do Q1.15 apos cada passo."""
        with torch.no_grad():
            for p in self.parameters():
                p.clamp_(-1.0, 1.0 - 2.0 ** -15)

    def features(self, x):
        w = fake_quant(self.conv.weight, self.bits)
        b = fake_quant(self.conv.bias, 16)          # bias sempre 16 bits
        y = F.conv2d(x, w, b, stride=1, padding=1)
        y = relu_sat(y)                             # saturacao + ReLU
        y = F.max_pool2d(y, 2)
        return y.mean(dim=(2, 3))                   # GAP

    def forward(self, x):
        w = fake_quant(self.dense.weight, self.bits)
        b = fake_quant(self.dense.bias, 16)
        s = F.linear(self.features(x), w, b)
        return torch.clamp(s, -1.0, 1.0)            # saturacao dos scores

    def pesos_inteiros(self):
        """Exporta no formato do RTL: inteiros Q1.15 (ker (8,9), bias, dw, db)."""
        def q(t, bits):
            qb = 2.0 ** (bits - 1)
            v = torch.clamp(torch.round(t.detach() * qb), -qb, qb - 1) / qb
            return torch.clamp(torch.round(v * 32768), -32768, 32767).long().cpu().numpy()
        ker = q(self.conv.weight.view(self.conv.out_channels, 9), self.bits)
        return {"ker": ker, "bias": q(self.conv.bias, 16),
                "dw": q(self.dense.weight, self.bits), "db": q(self.dense.bias, 16)}
