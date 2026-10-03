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
# As branches de origem trouxeram MEIA DUZIA de convencoes de resumo
# diferentes ("PASSARAM COM SUCESSO", "[CONGRATS]", "TESTES PASSARAM",
# "SUCCESS: All operations verified", "VALIDADA", ...). Perseguir cada
# redacao e perder tempo e, pior, marcar como falha um teste que passou.
#
# Um testbench e APROVADO quando as TRES condicoes valem:
#   (a) nenhuma linha COMECA com um marcador de falha;
#   (b) todo contador explicito de falhas que ele imprima e zero;
#   (c) aparece alguma frase de sucesso.
#
# Nenhuma basta sozinha. (a) e (b) sem (c) aprovariam um teste que travou
# antes de concluir; (c) sem (a) aprovaria um que imprime o resumo de sucesso
# mesmo tendo acusado falhas antes. E o marcador de (a) tem de ser casado no
# INICIO da linha: o tb_FP_Mult_Unit imprime o rotulo "Failures ([FAIL]) : 0",
# que uma busca solta por "[FAIL]" conta como falha.
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

        # Alguns testbenches antigos dependem de modulos que so existem em
        # arquivos com espaco e parentese no nome ("gauss_jordan_inv (2).v",
        # "fixed_point_divider (1).v"), fora da lista de fontes porque
        # duplicariam modulos. Se o erro foi modulo faltando, tenta de novo
        # incluindo-os -- assim esses testbenches rodam sem precisar que o
        # repositorio seja renomeado.
        if grep -q 'Unknown module type' "$log"; then
            EXTRA=()
            while IFS= read -r f; do EXTRA+=("$f"); done < <(ls *.v | grep ' ')
            if [ ${#EXTRA[@]} -gt 0 ] && iverilog -g2005 -o "$OUT/$nome.vvp" \
                    -s "$nome" "$tb" "${FONTES[@]}" "${EXTRA[@]}" > "$log" 2>&1
            then
                : # compilou na segunda tentativa
            else
                printf "%-32s %-10s %s\n" "$nome" "ERRO" "nao compila (ver log)"
                n_erro=$((n_erro+1)); FALHARAM+=("$nome: compilacao")
                sed -n '1,4p' "$log" | sed 's/^/      /'
                continue
            fi
        else
            printf "%-32s %-10s %s\n" "$nome" "ERRO" "nao compila (ver log)"
            n_erro=$((n_erro+1)); FALHARAM+=("$nome: compilacao")
            sed -n '1,4p' "$log" | sed 's/^/      /'
            continue
        fi
    fi

    # Teto de tempo: 300 s. O teste ponta a ponta, o mais demorado, leva ~120 s;
    # os de bloco, segundos.
    #
    # O '-k 5' e o '< /dev/null' nao sao zelo excessivo, sao necessarios. Um
    # testbench que chama $stop (o tb_autocorrelacao_yw chama) deixa o vvp num
    # PROMPT INTERATIVO, e ali ele IGNORA o SIGTERM que o timeout manda: sem o
    # -k, que manda SIGKILL depois da carencia, a regressao inteira fica presa
    # nele indefinidamente -- foram 54 minutos num teto nominal de 5. O stdin
    # em /dev/null faz esse prompt receber EOF em vez de esperar digitacao.
    if ! timeout -k 5 ${TETO:-300} vvp "$OUT/$nome.vvp" >> "$log" 2>&1 < /dev/null; then
        printf "%-32s %-10s %s\n" "$nome" "ERRO" "estourou o tempo ou abortou"
        n_erro=$((n_erro+1)); FALHARAM+=("$nome: execucao")
        continue
    fi

    RE_FALHA='^[[:space:]]*(>>>[[:space:]]*)?\[(FAIL|ERRO|ERR|FALHA)'
    RE_SUCESSO='PASSARAM|PASSOU|TESTS? PASSED|\[CONGRATS\]|SUCCESS|SUCESSO|VALIDAD|CONVERGIU'

    n_fail=$(grep -cE "$RE_FALHA" "$log" || true)

    # Contadores explicitos de falha, em qualquer das redacoes usadas
    # ("Falhas: N", "Falhas Detectadas: N", "Failures ([FAIL]) : N").
    # Toma-se o MAIOR: se o testbench imprime mais de um, basta um nao-zero.
    n_cont=$(sed -nE 's/.*(Falhas|Failures)[^0-9]*([0-9]+).*/\2/p' "$log" \
             | sort -rn | head -1)
    [ -z "$n_cont" ] && n_cont=0

    if grep -qE "$RE_SUCESSO" "$log" && [ "$n_fail" -eq 0 ] && [ "$n_cont" -eq 0 ]; then
        # Quantas verificacoes o testbench fez. Conta os marcadores de
        # sucesso e tambem o contador explicito, quando existe: o
        # tb_FP_Mult_Unit confere 2005 operacoes e imprime so o total, sem uma
        # linha por operacao -- contar apenas marcadores mostraria "0
        # verificacoes" num teste que fez milhares.
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
