===============================================================================
  SMMA - SUBSEÇÃO DE ESTIMAÇÃO MATRICIAL (AUTOCORRELAÇÃO & GAUSS-JORDAN)
===============================================================================

Este documento detalha a implementação em Verilog HDL dos módulos de Cálculo da 
Autocorrelação de Yule-Walker e Inversão Matricial via Gauss-Jordan, componentes 
do Smart Machine Monitoring Accelerator (SMMA).

A arquitetura foi projetada para processamento de sinais de vibração em motores 
elétricos, operando em ponto fixo (Q4.12 com palavra de 16 bits) e visando síntese 
em FPGA (placas Altera/Intel como a DE0-CV).

===============================================================================
1. SUMÁRIO DOS MÓDULOS
===============================================================================

1.1. autocorrelacao_yw.v
-------------------------------------------------------------------------------
Função: Calcula os 5 primeiros termos de autocorrelação normalizada (r[0] a r[4]) 
a partir de uma janela de 64 amostras de sinal de entrada.

- Interface de Entrada: Recebe as amostras em formato Q4.12 (lms_data) sincronizadas 
  por um pulso de validação (lms_valid).
- Processamento Interno:
  * Armazenamento: Registrador de deslocamento de 64 posições (shift_reg).
  * Datapath Aritmético: Reutiliza APENAS 2 multiplicadores combinacionais para 
    calcular as somas de produtos cruzados dos lags k in {0, 1, 2, 3, 4}, 
    otimizando área no FPGA.
  * Proteção contra Overflow: Utiliza acumuladores largos de 48 bits para somar 
    os 64 termos de produtos sem transbordamento.
  * Normalização: Instancia internamente uma unidade de divisão (fixed_point_divider) 
    para calcular r[k] = R_raw[k] / R_raw[0], garantindo que todas as saídas fiquem 
    contidas na faixa [-1.0, +1.0].
- Interface de Saída: Emite sequencialmente os valores r[0..4] usando o protocolo 
  r_valid, r_index e r_data.

1.2. gauss_jordan_inv.v
-------------------------------------------------------------------------------
Função: Executa a Inversão de Matrizes de dimensão até 4x4 usando o algoritmo de 
Eliminação de Gauss-Jordan com Pivotamento Parcial.

- Atribuição no Projeto: Recebe a Matriz de Autocorrelação de Toeplitz R gerada 
  pelos termos r[0..3] e calcula sua matriz inversa R^-1.
- Destaques da Arquitetura:
  * Pivotamento Parcial: Encontra o maior elemento da coluna (em valor absoluto) 
    para usar como pivô, prevenindo erros numéricos significativos em ponto fixo.
  * Tratamento de Tolerância/Singularidade: Compara o pivô com o parâmetro EPSILON. 
    Se o pivô for nulo ou menor que o limiar, o sinal singular é acionado para 
    evitar instabilidade.
  * Reutilização de Hardware: Compartilha um único multiplicador de ponto fixo 
    entre os estágios de normalização e eliminação gaussiana.
- Saída: A matriz inversa R^-1 fica disponível na memória interna do bloco, 
  acessível via endereçamento (read_row, read_col, read_data).

1.3. fixed_point_divider.v
-------------------------------------------------------------------------------
Função: Divisor sequencial em ponto fixo parametrizável baseado no algoritmo de 
Restoring Division (1 bit por ciclo de clock).

- Operação: Calcula o quociente entre um numerador de palavra dupla pré-deslocado 
  (numerator <<< FRAC) e um denominador, mantendo a precisão de fração intacta em Qm.f.
- Uso no Projeto:
  1. Instanciado dentro do autocorrelacao_yw para a normalização dos lags pela 
     energia R_raw[0].
  2. Instanciado dentro do gauss_jordan_inv para calcular o recíproco do pivô (1 / pivô).
- Flags de Controle: Fornece indicação de término (done) e alerta de divisão por 
  zero (div_by_zero).

===============================================================================
2. O QUE ESTES MÓDULOS OFERECEM AO SISTEMA (EXTRAÇÃO DE PARÂMETROS)
===============================================================================

1. Montagem da Matriz de Toeplitz (R):
   Os resultados r[0] a r[3] do módulo de autocorrelação formam a matriz de covariância 
   do sinal:

   R = [ r[0]  r[1]  r[2]  r[3] ]
       [ r[1]  r[0]  r[1]  r[2] ]
       [ r[2]  r[1]  r[0]  r[1] ]
       [ r[3]  r[2]  r[1]  r[0] ]

2. Extração de Características para Machine Learning:
   A resolução do sistema R * w = r gera o vetor de pesos de predição linear 
   w = [w1, w2, w3, w4]^T. Esses pesos representam os pólos espectrais da vibração 
   e são encaminhados ao classificador (MLP/SVM) para identificar falhas no motor 
   (Desbalanceamento, Desalinhamento, Desgaste de Rolamento).

===============================================================================
3. ESTRUTURA DE TESTES E SIMULAÇÃO
===============================================================================

Foram estruturados dois ambientes de testes em Verilog para validação 
comportamental e de integração:

3.1. Teste 1: Testbench Isolado da Autocorrelação (tb_autocorrelacao_yw.v)
-------------------------------------------------------------------------------
Objetivo: Validar ponta a ponta a exatidão matemática, o tempo de processamento e 
a normalização do módulo autocorrelacao_yw.v.

Como Funciona:
  1. Lê as 64 amostras reais da pasta (amostras_lms.txt) em formato Q4.12 Hexadecimal.
  2. Transmite as amostras uma a uma a cada ciclo de clock via lms_valid.
  3. Monitora o comportamento do sinal busy e aguarda os pulsos de r_valid.
  4. Converte e exibe os valores hexadecimais para números decimais reais no console.
  5. Verificação Automática: Valida se r[0] == 16'h1000 (1.0 em Q4.12), confirmando 
     que a normalização da janela funcionou corretamente sem estouro de bits.

3.2. Teste 2: Testbench de Pipeline Completo (tb_pipeline_completo.v)
-------------------------------------------------------------------------------
Objetivo: Validar o fluxo de dados integrado entre o módulo de Autocorrelação e 
o Inversor de Gauss-Jordan (integração do subsistema).

Como Funciona:
  1. Instancia ambos os DUTs (autocorrelacao_yw e gauss_jordan_inv).
  2. Envia o conjunto de 64 amostras para o módulo de autocorrelação e armazena 
     as saídas r[0..4] geradas.
  3. Task de Integração (carrega_e_inverte): Monta a matriz de Toeplitz 4x4 
     diretamente dos resultados reais obtidos e a carrega nos registradores do 
     gauss_jordan_inv.
  4. Dispara o procedimento de inversão do Gauss-Jordan e aguarda pela flag 
     gj_valid_out.
  5. Lê os elementos da matriz inversa R^-1 resultantes e os exibe convertidos em 
     notação de ponto flutuante.

===============================================================================
4. COMO EXECUTAR OS TESTES (ModelSim / EDA Playground / Icarus Verilog)
===============================================================================

1. Certifique-se de que o arquivo de dados amostras_lms.txt esteja presente no 
   mesmo diretório de execução.

2. Para rodar a verificação unitária do módulo de autocorrelação:
   vlog autocorrelacao_yw.v fixed_point_divider.v tb_autocorrelacao_yw.v
   vsim -c tb_autocorrelacao_yw -do "run -all"

3. Para rodar a verificação de integração completa:
   vlog autocorrelacao_yw.v gauss_jordan_inv.v fixed_point_divider.v tb_pipeline_completo.v
   vsim -c tb_pipeline_completo -do "run -all"
===============================================================================
