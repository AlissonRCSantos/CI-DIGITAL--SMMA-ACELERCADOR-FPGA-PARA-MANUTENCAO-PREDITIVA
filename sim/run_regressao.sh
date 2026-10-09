#!/bin/bash
# ============================================================================
# Regressao completa do SMMA com Icarus Verilog
#
#   ./sim/run_regressao.sh                 roda todos os testbenches
#   ./sim/run_regressao.sh tb_SMMA_Top     roda so os que casam com o nome
#   TETO=600 ./sim/run_regressao.sh        muda o teto de tempo por teste (s)
#
# Estrutura usada:
#   RTL/**/*.v          fontes de projeto (uma subpasta por modulo do PBL)
#   sim/tb/**/tb_*.v    testbenches (mesma organizacao do RTL)
#   quartus/vetores/    ROMs e vetores de teste (.hex) -- copiados para a
#                       pasta de execucao, porque os testbenches e as ROMs
#                       abrem "vetores/<arquivo>.hex" relativo ao diretorio
#                       corrente (o mesmo caminho que o Quartus usa).
#
# Um testbench e APROVADO quando as TRES condicoes valem:
#   (a) nenhuma linha COMECA com um marcador de falha ([FAIL], [ERRO], ...);
#   (b) todo contador explicito de falhas que ele imprima e zero;
#   (c) aparece alguma frase de sucesso.
# Nenhuma basta sozinha: (a)+(b) sem (c) aprovariam um teste que travou antes
# de concluir; (c) sem (a) aprovaria um que imprime o resumo mesmo com falhas.
# ============================================================================
set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RAIZ"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp -r quartus/vetores "$OUT/vetores"

FILTRO="${1:-}"

# Fontes de projeto
FONTES=()
while IFS= read -r f; do FONTES+=("$RAIZ/$f"); done < <(find RTL -name '*.v' | sort)

# Testbenches
TBS=()
while IFS= read -r f; do
    nome=$(basename "$f" .v)
    [ -n "$FILTRO" ] && [[ "$nome" != *"$FILTRO"* ]] && continue
    TBS+=("$f")
done < <(find sim/tb -name 'tb_*.v' | sort)

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

RE_FALHA='^[[:space:]]*(>>>[[:space:]]*)?\[(FAIL|ERRO|ERR|FALHA)'
RE_SUCESSO='PASSARAM|PASSOU|TESTS? PASSED|\[CONGRATS\]|SUCCESS|SUCESSO|VALIDAD|CONVERGIU'

for tb in "${TBS[@]}"; do
    nome=$(basename "$tb" .v)
    log="$OUT/$nome.log"

    if ! iverilog -g2005 -o "$OUT/$nome.vvp" -s "$nome" \
            "$RAIZ/$tb" "${FONTES[@]}" > "$log" 2>&1; then
        printf "%-32s %-10s %s\n" "$nome" "ERRO" "nao compila (ver log)"
        n_erro=$((n_erro+1)); FALHARAM+=("$nome: compilacao")
        sed -n '1,4p' "$log" | sed 's/^/      /'
        continue
    fi

    # Teto de tempo (padrao 300 s; o teste ponta a ponta leva ~100 s).
    # '-k 5' e '< /dev/null': um testbench que chame $stop deixa o vvp num
    # prompt interativo que ignora SIGTERM -- sem isso a regressao trava.
    if ! (cd "$OUT" && timeout -k 5 ${TETO:-300} vvp "$OUT/$nome.vvp" >> "$log" 2>&1 < /dev/null); then
        printf "%-32s %-10s %s\n" "$nome" "ERRO" "estourou o tempo ou abortou"
        n_erro=$((n_erro+1)); FALHARAM+=("$nome: execucao")
        continue
    fi

    n_fail=$(grep -cE "$RE_FALHA" "$log" || true)

    # Contadores explicitos de falha ("Falhas: N", "Failures ([FAIL]) : N")
    n_cont=$(sed -nE 's/.*(Falhas|Failures)[^0-9]*([0-9]+).*/\2/p' "$log" \
             | sort -rn | head -1)
    [ -z "$n_cont" ] && n_cont=0

    if grep -qE "$RE_SUCESSO" "$log" && [ "$n_fail" -eq 0 ] && [ "$n_cont" -eq 0 ]; then
        n_marc=$(grep -cE '^[[:space:]]*(>>>[[:space:]]*)?\[[[:space:]]*(PASS|OK)' "$log" || true)
        n_decl=$(sed -nE 's/.*(Sucessos|Successes)[^0-9]*([0-9]+).*/\2/p' "$log" \
                 | sort -rn | head -1)
        [ -z "$n_decl" ] && n_decl=0
        n_ok_tb=$n_marc
        [ "$n_decl" -gt "$n_ok_tb" ] && n_ok_tb=$n_decl
        printf "%-32s %-10s %s\n" "$nome" "OK" "$n_ok_tb verificacao(oes)"
        n_ok=$((n_ok+1))
    else
        if ! grep -qE "$RE_SUCESSO" "$log"; then
            det="sem resumo de sucesso"
        else
            det="$((n_fail + n_cont)) falha(s)"
        fi
        printf "%-32s %-10s %s\n" "$nome" "FALHOU" "$det"
        n_falha=$((n_falha+1)); FALHARAM+=("$nome: $det")
        grep -m 3 -E "$RE_FALHA" "$log" | sed 's/^/      /' || true
    fi
    [ -n "${MANTER_LOGS:-}" ] && cp "$log" "$MANTER_LOGS/" 2>/dev/null
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
