#!/bin/bash
# ==============================================================================
# Simulacao do acelerador CNN - Cadence Xcelium / SimVision
# Uso:
#   ./run_sim_cnn.sh tb_CNN_Top
#   ./run_sim_cnn.sh -c tb_CNN_Conv_Layer
#   ./run_sim_cnn.sh -c                     (apenas limpa)
# ==============================================================================

FILELIST="filelist_cnn.f"
DO_CLEAN=false
TB_TOP=""

show_help() {
    echo "======================================================================"
    echo " USO: $0 [-c|--clean] [-top <modulo>] [<modulo>]"
    echo "======================================================================"
    echo " Testbenches disponiveis:"
    echo "   tb_CNN_MAC_Unit          tb_CNN_ReLU"
    echo "   tb_CNN_Weight_ROM        tb_CNN_Line_Buffer"
    echo "   tb_CNN_Conv_Layer        tb_CNN_MaxPool"
    echo "   tb_CNN_Dense_Classifier  tb_CNN_Control_FSM"
    echo "   tb_CNN_Top               (teste de sistema completo)"
    echo "======================================================================"
    exit 0
}

clean_files() {
    echo "[CLEAN] Removendo arquivos temporarios da Cadence..."
    rm -rf xcelium.d .simvision simvision*.diag waves.shm \
           xrun.log xrun.history xrun.key .waves.shm.lockd
    echo "[CLEAN] Limpeza concluida!"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean) DO_CLEAN=true; shift ;;
        -top)       TB_TOP="$2"; shift 2 ;;
        -h|--help)  show_help ;;
        *)          if [ -z "$TB_TOP" ]; then TB_TOP="$1"; fi; shift ;;
    esac
done

if [ "$DO_CLEAN" = true ]; then
    clean_files
    if [ -z "$TB_TOP" ]; then exit 0; fi
fi

if [ -z "$TB_TOP" ]; then
    echo "[ERRO] Testbench nao especificado!"
    echo "Use: $0 <testbench>   (ex.: $0 tb_CNN_Top)"
    exit 1
fi

echo "[XRUN] Compilando e abrindo SimVision para o topo: '$TB_TOP'..."
xrun -gui \
     -access +rwc \
     -timescale 1ns/1ps \
     -f $FILELIST \
     -top $TB_TOP
