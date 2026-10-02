#!/bin/bash
# ============================================================================
# Regressao completa do SMMA com Icarus Verilog
#
# Roda todos os testbenches e resume o resultado. Diferente do run_sim.sh (que
# usa Cadence Xcelium, disponivel so no laboratorio), este depende apenas do
# iverilog e roda em qualquer maquina -- o que serve para conferir a entrega.
#
#   ./run_regressao.sh              roda tudo
#   ./run_regressao.sh tb_FFT_Top   roda so os testbenches cujo nome casa
#
# Um testbench e considerado APROVADO quando a saida contem "PASSARAM COM
# SUCESSO" e NAO contem "[FAIL]". Exigir as duas coisas e deliberado: ha
# testbenches que imprimem o resumo de sucesso mesmo tendo acusado falhas
# individuais antes, e so o resumo enganaria.
# ============================================================================
set -u

cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

FILTRO="${1:-}"

# Fontes de projeto: todo .v que nao e testbench.
#   - tb_*.v            : testbenches no padrao do projeto
#   - *_tb.v            : testbenches antigos (f0_estimator, peak_detector, mdc)
#   - nomes com espaco  : copias de trabalho ("gauss_jordan_inv (2).v"), que
#                         duplicariam modulos ja definidos
FONTES=()
while IFS= read -r f; do
    FONTES+=("$f")
done < <(ls *.v | grep -v '^tb_' | grep -v '_tb\.v$' | grep -v ' ')

# Testbenches a rodar
TBS=()
while IFS= read -r f; do
    [ -n "$FILTRO" ] && [[ "$f" != *"$FILTRO"* ]] && continue
    TBS+=("$f")
done < <(ls tb_*.v)

if [ ${#TBS[@]} -eq 0 ]; then
    echo "Nenhum testbench casa com '$FILTRO'"
    exit 1
fi

echo "======================================================================"
echo " REGRESSAO DO SMMA -- ${#TBS[@]} testbench(es), ${#FONTES[@]} fontes"
echo "======================================================================"
printf "\n%-32s %-10s %s\n" "TESTBENCH" "RESULTADO" "DETALHE"
printf -- "----------------------------------------------------------------------\n"

n_ok=0; n_falha=0; n_erro=0
FALHARAM=()

for tb in "${TBS[@]}"; do
    nome="${tb%.v}"
    log="$OUT/$nome.log"

    if ! iverilog -g2005 -o "$OUT/$nome.vvp" -s "$nome" \
            "$tb" "${FONTES[@]}" > "$log" 2>&1; then
        printf "%-32s %-10s %s\n" "$nome" "ERRO" "nao compila (ver log)"
        n_erro=$((n_erro+1)); FALHARAM+=("$nome: compilacao")
        sed -n '1,4p' "$log" | sed 's/^/      /'
        continue
    fi

    # Teto de tempo: o teste ponta a ponta leva minutos; os de bloco, segundos.
    if ! timeout 3600 vvp "$OUT/$nome.vvp" >> "$log" 2>&1; then
        printf "%-32s %-10s %s\n" "$nome" "ERRO" "estourou o tempo ou abortou"
        n_erro=$((n_erro+1)); FALHARAM+=("$nome: execucao")
        continue
    fi

    n_fail=$(grep -c '\[FAIL\]' "$log" || true)
    if grep -q 'PASSARAM COM SUCESSO' "$log" && [ "$n_fail" -eq 0 ]; then
        n_ok_tb=$(grep -c '\[PASS\]' "$log" || true)
        printf "%-32s %-10s %s\n" "$nome" "OK" "$n_ok_tb verificacao(oes)"
        n_ok=$((n_ok+1))
    else
        printf "%-32s %-10s %s\n" "$nome" "FALHOU" "$n_fail ocorrencia(s) de [FAIL]"
        n_falha=$((n_falha+1)); FALHARAM+=("$nome: $n_fail falha(s)")
        grep -m 3 '\[FAIL\]' "$log" | sed 's/^/      /'
    fi
done

printf -- "----------------------------------------------------------------------\n"
echo " $n_ok aprovado(s), $n_falha com falha, $n_erro com erro de compilacao/execucao"

if [ ${#FALHARAM[@]} -gt 0 ]; then
    echo
    echo " Pendencias:"
    for f in "${FALHARAM[@]}"; do echo "   - $f"; done
fi
echo "======================================================================"

[ $((n_falha + n_erro)) -eq 0 ]
