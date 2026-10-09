# SMMA -- restricoes de tempo: um unico relogio, CLOCK_50 (50 MHz)

create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# botoes, chaves, LEDs e displays sao assincronos (os botoes passam por
# sincronizadores no SMMA_Top)
set_false_path -from [get_ports {KEY[*]}]
set_false_path -from [get_ports {SW[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
set_false_path -to   [get_ports {HEX0[*]}]
set_false_path -to   [get_ports {HEX1[*]}]
set_false_path -to   [get_ports {HEX2[*]}]
set_false_path -to   [get_ports {HEX3[*]}]
set_false_path -to   [get_ports {HEX4[*]}]
set_false_path -to   [get_ports {HEX5[*]}]
