# ============================================================================
# sim_latencia.do -- roda o testbench de latencia (latencia_tb.v) no ModelSim
#
# Uso, no Transcript do ModelSim, com a pasta RTL como diretorio atual:
#
#   do sim_latencia.do          modo rapido (FAST=1): fonte sem espera, ~84 mil ciclos
#   do sim_latencia.do 0 100    tempo real com DIV_TAXA=100: ~860 mil ciclos (mais lento)
#
# Por que rodar a partir de RTL/: os modulos abrem "vetores/*.hex" com caminho
# relativo. Rodando de outra pasta, as ROMs ficam vazias e o resultado e lixo.
# ============================================================================

set fast 1
set div  100
if {$argc >= 1} { set fast $1 }
if {$argc >= 2} { set div  $2 }

# confere se estamos na pasta certa
if {![file exists vetores/demo_amostras.hex]} {
    echo "ERRO: rode a partir da pasta RTL (vetores/demo_amostras.hex nao encontrado)."
    echo "      Use: cd {<caminho do projeto>/RTL}"
    return
}

# biblioteca de trabalho limpa
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

# compila so as fontes do projeto (sem testbenches e sem as copias com espaco no nome)
foreach f [lsort [glob *.v]] {
    if {[string match "* *" $f]}   { continue }
    if {[string match "tb_*" $f]}  { continue }
    if {[string match "*_tb.v" $f]} { continue }
    vlog -quiet -work work $f
}
vlog -quiet -work work latencia_tb.v

# simula; -onfinish stop mantem as ondas abertas depois do $finish
vsim -voptargs=+acc -onfinish stop -gFAST=$fast -gDIV=$div work.tb_latencia

# sinais uteis para ver o fluxo de uma janela nas ondas
add wave -divider "Painel"
add wave sim:/tb_latencia/KEY
add wave sim:/tb_latencia/LEDR
add wave -divider "Fonte e FIR"
add wave sim:/tb_latencia/uut/r_arranca
add wave sim:/tb_latencia/uut/src_valid
add wave -radix decimal sim:/tb_latencia/uut/src_sample
add wave sim:/tb_latencia/uut/dec_valid
add wave -radix decimal sim:/tb_latencia/uut/dec_sample
add wave -divider "FFT"
add wave sim:/tb_latencia/uut/fft_start
add wave sim:/tb_latencia/uut/fft_done
add wave sim:/tb_latencia/uut/fft_out_valid
add wave -radix unsigned sim:/tb_latencia/uut/fft_out_index
add wave sim:/tb_latencia/uut/bin_aceito
add wave -divider "Classificadores"
add wave sim:/tb_latencia/uut/fs_out_valid
add wave sim:/tb_latencia/uut/ft_out_valid
add wave sim:/tb_latencia/uut/tree_out_valid
add wave -radix unsigned sim:/tb_latencia/uut/tree_class
add wave sim:/tb_latencia/uut/sb_out_valid
add wave sim:/tb_latencia/uut/cnn_valid
add wave -radix unsigned sim:/tb_latencia/uut/cnn_class
add wave -radix unsigned sim:/tb_latencia/uut/est

run -all
wave zoom full
