# SMMA — Acelerador FPGA para Manutenção Preditiva

**Smart Machine Monitoring Accelerator.** Diagnostica falhas em motores
elétricos (normal, desbalanceamento, desalinhamento, rolamento) a partir da
vibração, inteiramente em hardware, numa DE0-CV (Cyclone V, 50 MHz).
PBL de Circuitos Digitais IV — CI Digital / CEPEDI.

![Arquitetura](docs/diagramas/SMMA_arquitetura.png)

O diagrama segue o desenho do grupo:
- **LMS** na entrada → **Data Bus Driver**;
- ramo FFT: MEM_A → FFT → MEM_B → detector de picos → Euclides;
- ramo de parâmetros: acumulador de coeficientes → Gauss-Jordan;
- os dois ramos chegam ao **Parameter RegFile** → **árvore de decisão**.

Os blocos marcados como NOVO são os obrigatórios que faltavam: FIR/decimação,
f0, ramo CNN, controle global e saída.

## Começar

| quero… | ver |
|---|---|
| compilar, gravar e usar na placa | [docs/QUARTUS_E_PLACA.md](docs/QUARTUS_E_PLACA.md) |
| entender a arquitetura e a relação dos módulos | [docs/ARQUITETURA.md](docs/ARQUITETURA.md) |
| simular (39 testbenches) | [docs/VERIFICACAO.md](docs/VERIFICACAO.md) |
| treinar / regerar as ROMs | [python/README.md](python/README.md) |
| ver a organização das pastas | [docs/SMMA_organizacao_pastas.pdf](docs/SMMA_organizacao_pastas.pdf) |

## Pastas

```
RTL/                 Verilog sintetizável — uma pasta por bloco do diagrama
  top/               SMMA_Top, controle global, painel de saída
  entrada/           sensor Xa (ROM do dataset), FIR + decimação /8
  lms/               LMS em série (LMS_Stage) e filtro LMS de 8 coeficientes
  barramento/        Data Bus Driver e Stream_Fork (handshake)
  memorias/          MEM_A (Frame_Builder) e MEM_B (Spectrum_Accumulator)
  fft/               FFT de 64 pontos
  mdc/               detector de picos, Euclides (MDC), f0
  matriz/            autocorrelação, Yule-Walker, Gauss-Jordan
  ml/                características, Parameter RegFile, árvore de decisão
  cnn/               log2, espectrograma, CNN
  aritmetica/        multiplicador, somador e divisores em ponto fixo
sim/                 testbenches (mesmas pastas do RTL) e scripts de simulação
quartus/             projeto Quartus (.qpf/.qsf/.sdc) e vetores/ (.hex das ROMs)
python/              treino, quantização e geração das ROMs
docs/                documentação, enunciado e diagramas
dados/               dataset (local, fora do git)
```

## Resultados

- **Na placa** (12 janelas): árvore **11/12**, CNN **10/12**, f0 = **50 Hz**.
- **Processamento:** a decisão sai ~0,2 ms depois da última amostra.
- **Quartus:** fecha a 50 MHz com slack de +2,96 ns e usa 56% das ALMs,
  66% dos M10K e 36% dos DSPs.

| teste (4021 janelas) | 0 N·m | 2 N·m | 4 N·m | geral |
|---|---|---|---|---|
| **Árvore** | 0,9725 | 0,9354 | 0,8832 | 0,9321 |
| CNN | 0,893 | 0,862 | 0,738 | 0,832 |

Dataset: Jung et al., *Data in Brief* 48 (2023), KAIST —
[doi:10.1016/j.dib.2023.109049](https://doi.org/10.1016/j.dib.2023.109049).
