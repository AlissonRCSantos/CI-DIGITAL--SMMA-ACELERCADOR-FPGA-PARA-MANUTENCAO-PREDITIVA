# ============================================================================
# SMMA -- restricoes de tempo (Synopsys Design Constraints)
#
# O projeto tem UM unico dominio de relogio: o CLOCK_50 da placa. Nao ha PLL,
# nem clock derivado, nem travessia entre dominios -- o que elimina de partida
# a classe de bug mais dificil de achar em FPGA.
# ============================================================================

create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# Incerteza de relogio (jitter da placa + o que a ferramenta estima)
derive_clock_uncertainty

# ----------------------------------------------------------------------------
# Entradas e saidas assincronas
#
# KEY e SW vem de botoes e chaves mecanicas e nao tem relacao com o relogio;
# LEDR e HEX vao para LEDs que ninguem le em nanossegundos. Restringir esses
# caminhos nao melhora nada e enche o relatorio de falhas de I/O que escondem
# as falhas reais do caminho interno.
#
# Os dois botoes passam por dois registradores dentro do SMMA_Top antes de
# chegar a qualquer FSM, que e o que de fato trata a metaestabilidade --
# false_path aqui so informa a ferramenta de que a analise nao se aplica.
# ----------------------------------------------------------------------------
set_false_path -from [get_ports {KEY[*]}]
set_false_path -from [get_ports {SW[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
set_false_path -to   [get_ports {HEX0[*]}]
set_false_path -to   [get_ports {HEX1[*]}]
set_false_path -to   [get_ports {HEX2[*]}]
set_false_path -to   [get_ports {HEX3[*]}]
set_false_path -to   [get_ports {HEX4[*]}]
set_false_path -to   [get_ports {HEX5[*]}]
