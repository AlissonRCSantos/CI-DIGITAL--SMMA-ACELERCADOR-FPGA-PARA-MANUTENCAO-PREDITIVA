#!/bin/bash

# ==============================================================================
# Script de Automação de Simulação - Cadence Xcelium / SimVision
# ==============================================================================

FILELIST="filelist.f"
DO_CLEAN=false
USE_GUI=true
TB_TOP=""

# Função de Ajuda
show_help() {
    echo "======================================================================"
    echo " USO: $0 [-c|--clean] [-cmd] [-top <nome_do_modulo>] [nome_do_modulo]"
    echo "======================================================================"
    echo " Opções:"
    echo "   -c, --clean    Limpa arquivos de compilação/logs temporários antigos"
    echo "   -cmd           Executa em modo linha de comando (sem interface gráfica GUI)"
    echo "   -top <modulo>  Especifica o módulo Top/Testbench"
    echo "   -h, --help     Exibe esta mensagem de ajuda"
    echo ""
    echo " Exemplos:"
    echo "   $0 tb_LMS_Control_FSM             --> Roda com interface gráfica (SimVision)"
    echo "   $0 -cmd tb_LMS_Control_FSM        --> Roda em modo texto no terminal"
    echo "   $0 -c -cmd -top tb_LMS_Control_FSM--> Limpa e roda em modo texto"
    echo "======================================================================"
    exit 0
}

# Função de Limpeza
clean_files() {
    echo "[CLEAN] Removendo arquivos temporários da Cadence..."
    rm -rf xcelium.d \
           .simvision \
           simvision*.diag \
           waves.shm \
           xrun.log \
           xrun.history \
           xrun.key \
           .waves.shm.lockd
    echo "[CLEAN] Limpeza concluída!"
}

# --- PROCESSAMENTO DOS ARGUMENTOS ---
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        -cmd|--cmd)
            USE_GUI=false
            shift
            ;;
        -top)
            TB_TOP="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            if [ -z "$TB_TOP" ]; then
                TB_TOP="$1"
            fi
            shift
            ;;
    esac
done

# 1. Executa limpeza se foi solicitada
if [ "$DO_CLEAN" = true ]; then
    clean_files
    if [ -z "$TB_TOP" ]; then
        exit 0
    fi
fi

# 2. Validação do Topo
if [ -z "$TB_TOP" ]; then
    echo "[ERRO] Módulo Top/Testbench não especificado!"
    echo "Use: $0 <nome_do_modulo> ou $0 -top <nome_do_modulo>"
    exit 1
fi

# 3. Definição do modo de execução (GUI vs Batch)
GUI_FLAG=""
if [ "$USE_GUI" = true ]; then
    GUI_FLAG="-gui"
    echo "[XRUN] Compilando e iniciando interface SimVision para o topo: '$TB_TOP'..."
else
    GUI_FLAG=""
    echo "[XRUN] Compilando e simulando em Modo Texto (CLI) para o topo: '$TB_TOP'..."
fi

# 4. Execução do Xcelium
xrun $GUI_FLAG \
     -access +rwc \
     -timescale 1ns/1ps \
     -f $FILELIST \
     -top $TB_TOP