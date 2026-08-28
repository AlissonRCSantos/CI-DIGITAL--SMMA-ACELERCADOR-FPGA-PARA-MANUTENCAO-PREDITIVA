#!/bin/bash

# ==============================================================================
# Script de Automação de Simulação - Cadence Xcelium / SimVision
# ==============================================================================

FILELIST="filelist.f"
DO_CLEAN=false
TB_TOP=""

# Função de Ajuda
show_help() {
    echo "======================================================================"
    echo " USO: $0 [-c|--clean] [-top <nome_do_modulo>] [nome_do_modulo]"
    echo "======================================================================"
    echo " Opções:"
    echo "   -c, --clean    Limpa arquivos de compilação/logs temporários antigos"
    echo "   -top <modulo>  Especifica o módulo Top/Testbench"
    echo "   -h, --help     Exibe esta ajuda"
    echo ""
    echo " Formas de Uso Válidas:"
    echo "   $0 FP_Arith_Unit"
    echo "   $0 -c FP_Arith_Unit"
    echo "   $0 -c -top FP_Arith_Unit"
    echo "   $0 -c                     (Apenas limpa a pasta)"
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

# --- PROCESSAMENTO INTELIGENTE DOS ARGUMENTOS ---
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        -top)
            # Se usou "-top nome", pega o próximo parâmetro
            TB_TOP="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            # Se não começa com '-', é o nome do topo
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
    # Se passou apenas -c (sem topo), encerra
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

# 3. Execução do Xcelium
echo "[XRUN] Compilando e abrindo SimVision para o topo: '$TB_TOP'..."

xrun -gui \
     -access +rwc \
     -timescale 1ns/1ps \
     -f $FILELIST \
     -top $TB_TOP