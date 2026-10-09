# ============================================================================
# sim_latencia.do -- roda o testbench de latencia (sim/tb/top/tb_latencia.v)
#
# Uso, no Transcript do ModelSim, com a pasta quartus/ como diretorio atual:
#
#   do ../sim/modelsim/sim_latencia.do          modo rapido (FAST=1)
#   do ../sim/modelsim/sim_latencia.do 0 100    tempo real com DIV_TAXA=100
#
# Por que a partir de quartus/: os modulos abrem "vetores/*.hex" com caminho
# relativo. Rodando de outra pasta, as ROMs ficam vazias e o resultado e lixo.
# ============================================================================

set fast 1
set div  100
if {$argc >= 1} { set fast $1 }
if {$argc >= 2} { set div  $2 }

# confere se estamos na pasta certa
if {![file exists vetores/demo_amostras.hex]} {
    echo "ERRO: rode a partir da pasta quartus (vetores/demo_amostras.hex nao encontrado)."
    echo "      Use: cd {<caminho do projeto>/quartus}"
    return
}

# biblioteca de trabalho limpa
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

# compila o RTL inteiro (uma pasta por modulo) e o testbench de latencia
foreach dir {top entrada buffers fft mdc lms matriz ml cnn comum} {
    foreach f [lsort [glob ../RTL/$dir/*.v]] { vlog -quiet -work work $f }
}
vlog -quiet -work work ../sim/tb/top/tb_latencia.v

# simula; -onfinish stop mantem as ondas abertas depois do $finish
vsim -voptargs=+acc -onfinish stop -gFAST=$fast -gDIV=$div work.tb_latencia

# sinais uteis para ver o fluxo de uma janela nas ondas
add wave -divider "Painel"
add wave sim:/tb_latencia/KEY
add wave sim:/tb_latencia/LEDR
add wave -divider "Fonte e FIR"
add wave sim:/tb_latencia/uut/arranca
add wave sim:/tb_latencia/uut/src_valid
add wave -radix decimal sim:/tb_latencia/uut/src_sample
add wave sim:/tb_latencia/uut/dec_valid
add wave -radix decimal sim:/tb_latencia/uut/dec_sample
add wave -divider "FFT e espectro"
add wave sim:/tb_latencia/uut/fft_start
add wave sim:/tb_latencia/uut/fft_done
add wave sim:/tb_latencia/uut/fft_out_valid
add wave -radix unsigned sim:/tb_latencia/uut/fft_out_index
add wave sim:/tb_latencia/uut/sa_out_valid
add wave -radix unsigned sim:/tb_latencia/uut/sa_out_mag
add wave -divider "MDC"
add wave -radix unsigned sim:/tb_latencia/uut/pk_out_data
add wave -radix unsigned sim:/tb_latencia/uut/mdc_k0
add wave -radix unsigned sim:/tb_latencia/uut/f0_int
add wave -divider "LMS e matriz"
add wave sim:/tb_latencia/uut/lms_start
add wave -radix decimal sim:/tb_latencia/uut/lms_error
add wave sim:/tb_latencia/uut/lr_out_valid
add wave sim:/tb_latencia/uut/ac_r_valid
add wave -radix decimal sim:/tb_latencia/uut/ac_r_data
add wave sim:/tb_latencia/uut/inv_start
add wave sim:/tb_latencia/uut/inv_valid_out
add wave -radix decimal sim:/tb_latencia/uut/yw_out_feature
add wave -divider "Classificadores"
add wave sim:/tb_latencia/uut/col_out_valid
add wave -radix decimal sim:/tb_latencia/uut/col_out_feature
add wave sim:/tb_latencia/uut/tree_out_valid
add wave -radix unsigned sim:/tb_latencia/uut/tree_class
add wave sim:/tb_latencia/uut/cnn_valid
add wave -radix unsigned sim:/tb_latencia/uut/cnn_class
add wave -radix unsigned sim:/tb_latencia/uut/u_ctrl/est

run -all
wave zoom full
