# ============================================================================
# sim_tb.do -- compila o RTL inteiro e roda UM testbench no ModelSim/Questa
#
# Uso, no Transcript do ModelSim, com a pasta quartus/ como diretorio atual
# (File > Change Directory... > <projeto>/quartus):
#
#   do ../sim/modelsim/sim_tb.do tb_SMMA_Top
#   do ../sim/modelsim/sim_tb.do tb_MDC_Chain
#
# Por que a partir de quartus/: os modulos abrem "vetores/*.hex" com caminho
# relativo -- o mesmo caminho que o Quartus usa na sintese.
# ============================================================================

if {$argc < 1} { echo "Uso: do ../sim/modelsim/sim_tb.do <tb_nome>"; return }
set tb $1

if {![file exists vetores/demo_amostras.hex]} {
    echo "ERRO: rode a partir da pasta quartus/ (vetores/demo_amostras.hex nao encontrado)."
    return
}

if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

foreach dir {top entrada buffers fft mdc lms matriz ml cnn comum} {
    foreach f [lsort [glob ../RTL/$dir/*.v]] { vlog -quiet -work work $f }
}
set tbfile [lindex [glob -nocomplain ../sim/tb/*/$tb.v] 0]
if {$tbfile == ""} { echo "ERRO: $tb.v nao encontrado em sim/tb"; return }
vlog -quiet -work work $tbfile

vsim -voptargs=+acc -onfinish stop work.$tb
run -all
