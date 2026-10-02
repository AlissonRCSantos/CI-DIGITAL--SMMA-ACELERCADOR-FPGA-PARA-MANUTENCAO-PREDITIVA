"""
config.py -- Parametros UNICOS do fluxo de treinamento da CNN do SMMA.

Tudo que precisa ser igual entre Python e hardware esta aqui. Se mudar algo,
rode de novo os scripts a partir do passo afetado.
"""
import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Caminhos (relativos a raiz do repositorio)
# ---------------------------------------------------------------------------
RAIZ          = Path(os.environ.get("SMMA_RAIZ", Path(__file__).resolve().parent.parent))
DIR_CSV       = RAIZ / "dados" / "Dataset - vibração"
# Formato NATIVO do dataset (Jung et al. distribuem .mat; o CSV e uma
# exportacao ~6x maior). Use o passo 01b para ler daqui.
DIR_MAT       = RAIZ / "dataset" / "vibration"
DIR_BRUTOS    = RAIZ / "dados" / "processado" / "brutos"        # saida do passo 01
DIR_ESPEC     = RAIZ / "dados" / "processado" / "espectrogramas"  # saida do passo 02
DIR_RESULT    = RAIZ / "python" / "resultados"                  # modelos, relatorios
DIR_RTL       = RAIZ / "RTL"

# ---------------------------------------------------------------------------
# Dataset (Jung et al., Data in Brief 48, 2023 -- KAIST)
# ---------------------------------------------------------------------------
FS_ORIGINAL   = 25_600          # Hz, taxa dos acelerometros
# Colunas do CSV: Tempo, Canal1=x_A, Canal2=y_A, Canal3=x_B, Canal4=y_B.
# Todas as falhas foram inseridas junto ao mancal A -> guardamos so Canal1/2.
COLUNAS_CSV   = (1, 2)
CANAL         = 0               # indice dentro de COLUNAS_CSV: 0=Canal1(x_A) 1=Canal2(y_A)

# Classes pedidas no enunciado do PBL (secao 3.5) -- mesma ordem da ROM
CLASSES = ["normal", "desbalanceamento", "desalinhamento", "rolamento"]

def classe_do_arquivo(nome: str) -> int:
    n = nome.lower()
    if "normal" in n:                     return 0
    if "unbal" in n:                      return 1   # (ha arquivos 'Unbalalnce')
    if "misalign" in n:                   return 2
    if "bpfi" in n or "bpfo" in n:        return 3
    raise ValueError(f"classe desconhecida: {nome}")

# ---------------------------------------------------------------------------
# Espectrograma -- ESTA E A ESPECIFICACAO DO BLOCO DE HARDWARE
# ---------------------------------------------------------------------------
DECIMACAO     = 8                          # 25.6 kHz -> 3.2 kHz
FS            = FS_ORIGINAL // DECIMACAO   # 3200 Hz
NFIR          = 63                         # taps do FIR anti-aliasing
NFFT          = 64                         # FFT de 64 pontos (enunciado 3.2)
HOP           = 32                         # 32 amostras @3.2 kHz = 10 ms (enunciado 5)
NBINS         = 32                         # bins 0..31 (0 .. 1550 Hz, 50 Hz/bin)
NQUADROS      = 32                         # 32 FFTs por imagem -> 32x32
PASSO_IMAGEM  = 16                         # nova imagem a cada 16 FFTs (160 ms) no dataset
# Compressao de amplitude aplicada a |X| (ver smma/espectrograma.py)
ESCALA        = "log2"                     # "log2" ou "linear"

# ---------------------------------------------------------------------------
# Divisao treino/validacao/teste -- POR TEMPO dentro de cada arquivo
# (janelas vizinhas sao quase iguais; sortear misturaria treino e teste)
# ---------------------------------------------------------------------------
FRACAO_TREINO = 0.70
FRACAO_VALID  = 0.15               # o restante (0.15) e teste
GUARDA_S      = 0.5                # s descartados entre as fatias

# ---------------------------------------------------------------------------
# Ponto fixo (igual ao RTL)
# ---------------------------------------------------------------------------
WIDTH = 16
FRAC  = 15
GAP_SHIFT = 8
SEMENTE = 1234
