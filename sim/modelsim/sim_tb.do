# Compila o RTL e roda UM testbench no ModelSim/Questa.
# Rodar com a pasta quartus/ como diretorio atual:  do ../sim/modelsim/sim_tb.do tb_SMMA_Top

if {$argc < 1} { echo "Uso: do ../sim/modelsim/sim_tb.do <tb_nome>"; return }
set tb $1

if {![file exists vetores/demo_amostras.hex]} {
    echo "ERRO: rode a partir da pasta quartus/ (vetores/demo_amostras.hex nao encontrado)."
    return
}

if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

foreach f [lsort [glob ../RTL/*/*.v]] { vlog -quiet -work work $f }
set tbfile [lindex [glob -nocomplain ../sim/tb/*/$tb.v] 0]
if {$tbfile == ""} { echo "ERRO: $tb.v nao encontrado em sim/tb"; return }
vlog -quiet -work work $tbfile

vsim -voptargs=+acc -onfinish stop work.$tb
run -all
