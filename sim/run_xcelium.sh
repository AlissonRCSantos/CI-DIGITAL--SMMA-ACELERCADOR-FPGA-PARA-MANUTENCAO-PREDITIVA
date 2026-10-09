#!/bin/bash
# Simulacao com Cadence Xcelium/SimVision (laboratorio), a partir de quartus/
#   ./sim/run_xcelium.sh tb_SMMA_Top       abre o SimVision
#   ./sim/run_xcelium.sh -cmd tb_FFT_Top   modo texto
#   ./sim/run_xcelium.sh -c                limpa os arquivos da Cadence

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
GUI_FLAG="-gui"; TB_TOP=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean)
            (cd "$RAIZ/quartus" && rm -rf xcelium.d .simvision simvision*.diag waves.shm \
                xrun.log xrun.history xrun.key .waves.shm.lockd)
            echo "[CLEAN] ok"; [ -z "$TB_TOP" ] && [ $# -eq 1 ] && exit 0; shift ;;
        -cmd) GUI_FLAG=""; shift ;;
        *)    TB_TOP="$1"; shift ;;
    esac
done

[ -z "$TB_TOP" ] && { echo "Uso: $0 [-cmd] <tb_nome>"; exit 1; }
TB_FILE=$(find "$RAIZ/sim/tb" -name "$TB_TOP.v" | head -1)
[ -z "$TB_FILE" ] && { echo "[ERRO] $TB_TOP.v nao encontrado em sim/tb"; exit 1; }

cd "$RAIZ/quartus"
sed "s|^RTL/|$RAIZ/RTL/|" "$RAIZ/sim/filelist.f" > /tmp/smma_filelist.f
xrun $GUI_FLAG -access +rwc -timescale 1ns/1ps -f /tmp/smma_filelist.f "$TB_FILE" -top "$TB_TOP"
