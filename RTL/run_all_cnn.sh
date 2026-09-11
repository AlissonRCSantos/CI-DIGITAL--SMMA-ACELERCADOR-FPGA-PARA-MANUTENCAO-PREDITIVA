#!/bin/bash
# ============================================================================
# run_all_cnn.sh -- executa TODOS os testbenches do acelerador CNN
#                   usando Icarus Verilog (simulador livre, multiplataforma).
#
# Uso:  ./run_all_cnn.sh            roda a suite completa
#       ./run_all_cnn.sh CNN_Top    roda apenas o testbench indicado
#
# Para simular com Cadence Xcelium (fluxo do laboratorio), use:
#       ./run_sim_cnn.sh -c tb_CNN_Top
# ============================================================================

set -u
RTL="CNN_MAC_Unit.v CNN_ReLU.v CNN_Weight_ROM.v CNN_Line_Buffer.v \
     CNN_Conv_Layer.v CNN_MaxPool.v CNN_Dense_Classifier.v \
     CNN_Control_FSM.v CNN_Top.v"

MODULES="CNN_MAC_Unit CNN_ReLU CNN_Weight_ROM CNN_Line_Buffer \
         CNN_Conv_Layer CNN_MaxPool CNN_Dense_Classifier \
         CNN_Control_FSM CNN_Top"

[ $# -gt 0 ] && MODULES="$*"

mkdir -p sim_out
PASS=0; FAIL=0

for M in $MODULES; do
    TB="tb_${M}.v"
    if [ ! -f "$TB" ]; then
        echo "!! testbench $TB nao encontrado"; FAIL=$((FAIL+1)); continue
    fi

    echo ""
    echo "############################################################"
    echo "# Simulando: tb_${M}"
    echo "############################################################"

    if ! iverilog -g2005 -o "sim_out/${M}.vvp" -s "tb_${M}" "$TB" $RTL 2> "sim_out/${M}.compile.log"; then
        echo "ERRO DE COMPILACAO:"; cat "sim_out/${M}.compile.log"
        FAIL=$((FAIL+1)); continue
    fi

    vvp "sim_out/${M}.vvp" | tee "sim_out/${M}.log"

    if grep -q "TODOS OS" "sim_out/${M}.log"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "############################################################"
echo "# RESUMO DA SUITE:  $PASS modulo(s) OK, $FAIL com falha"
echo "############################################################"
[ "$FAIL" -eq 0 ] || exit 1
