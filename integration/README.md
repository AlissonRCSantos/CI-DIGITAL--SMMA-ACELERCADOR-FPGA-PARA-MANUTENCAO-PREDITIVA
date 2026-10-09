# Integração SMMA

`RTL/SMMA_Top.v` integra estes blocos das branches remotas:

- `feat/LMS`: filtro adaptativo de 8 taps;
- `fft`: FFT radix-2 de 64 pontos e unidades de ponto fixo;
- `feat/peak_detector`: detector dos três maiores picos locais;
- `feat/MDC`: MDC dos três bins detectados;
- `feat/frequency`: estimador de frequência fundamental;
- `feat/CNN`: classificador CNN;
- `feat/inverse-matrix`: inversor Gauss-Jordan e divisor;
- `feat/fixed_poit`: a branch remota usa esse nome (typo); contém as unidades de ponto fixo também presentes no LMS/FFT. A integração mantém uma única cópia dessas unidades.

O fluxo conectado é **LMS → buffer de 64 amostras → FFT → detector de picos → MDC → f0**. O top aceita uma amostra LMS por vez (`sample_start` e `sample_valid` juntos, quando `sample_ready` está alto). `analysis_done` sinaliza a conclusão da cadeia espectral e libera uma nova janela. Os bins de pico são transmitidos internamente com `valid/ready`; o bin fundamental e a frequência ficam nas saídas `fundamental_bin`, `fundamental_hz_int` e `fundamental_hz_frac`.

O classificador de árvore e o seu front-end da branch `top_level` foram integrados. O caminho automático recebe `sample_x` e calcula: FIR de 63 taps + decimação por 8; 32 quadros FFT de 64 pontos com hop 32; 8 features espectrais; e 4 temporais. As features seguem na ordem treinada: `r_1x`, `r_2x`, `r_3x`, três energias de banda, `log2E`, centroide, `r_lms`, `rho1`, `rho2`, `rho3`. A árvore usa a ROM de 141 nós `RTL/vetores/arvore.hex`.

Como no `top_level` atualizado, árvore e CNN processam a mesma janela e produzem classes comparáveis. A imagem para a CNN é montada e transposta pelo buffer de espectrograma, após compressão log2 das magnitudes FFT. O `CNN_Top` existente é compartilhado: por padrão usa esse caminho automático (`AUTO_CNN_FROM_VIBRATION=1`); para o modo antigo de pixels externos, configure o parâmetro como 0. Nesse modo, as saídas `cnn_class`, `cnn_valid` e `cnn_busy` correspondem ao caminho selecionado. As saídas `auto_cnn_*` identificam especificamente o resultado automático.

Por padrão, a fonte faz parte do RTL sintetizável: `Vibration_ROM_Source` lê a ROM síncrona `RTL/vetores/vibration_input.hex`, marcada para inferência em M10K. `dataset_start` inicia a leitura, e `dataset_busy`/`dataset_done` indicam o progresso da reprodução. Cada entrada ROM tem 32 bits `{sample_d[15:0], sample_x[15:0]}`; a fonte emite 8503 amostras por janela a 25,6 kHz (`DATA_ROM_RATE_DIV=1953`). Para usar um ADC ou outra fonte de stream, configure `USE_VIBRATION_ROM=0`; nesse modo o top aceita `sample_*` e sinaliza `sample_ready`.

O resultado da árvore aparece em `auto_tree_class` durante `auto_tree_class_valid`; `auto_tree_done` sinaliza a conclusão da árvore e `auto_tree_error` indica percurso inválido. A CNN sinaliza a conclusão em `auto_cnn_done` e sua classe em `auto_cnn_class` durante `auto_cnn_class_valid`. O caminho recebe janelas contíguas de 8503 amostras e reinicia após ambas as classificações. A interface manual `tree_*` continua disponível para testes com um vetor de features externo.

O inversor usa a interface independente `inv_*`, pois o PBL não define a origem da matriz de estimação. Por padrão, o espectrograma da CNN é calculado internamente com a mesma janela da árvore. A interface manual `cnn_*` pode ser selecionada com `AUTO_CNN_FROM_VIBRATION=0`. Carregue todos os elementos de A antes de `inv_start`.

## Requisitos considerados

- Clock alvo de 50 MHz, reset ativo alto e habilitação global.
- FFT de 64 pontos no caminho legado e 32 quadros de 64 pontos (hop 32) no caminho da árvore.
- Janela da árvore de 1056 amostras decimadas, obtidas de 8503 amostras brutas a 25,6 kHz.
- LMS com 8 coeficientes; formato padrão Q1.15.
- Três picos acima de `peak_threshold`; `min_gcd_bin` filtra MDC inválido.
- Frequência fundamental calculada a partir de `sample_rate_hz` e do bin MDC.
- CNN para imagem 32×32×1 e quatro classes.
- Inversão Gauss-Jordan até 4×4, com tratamento de pivô pequeno pelo epsilon.
- Sinais de handshaking e estado de conclusão entre os módulos conectados.

## Fontes e compilação

As fontes originais foram preservadas em `RTL/blocks/`. Da branch `top_level`, foram trazidos o classificador, ROM, filtro/decimador, montador de quadros e extratores espectral/temporal necessários ao caminho da árvore. O restante do top-level daquela branch não foi reutilizado. A cadeia original LMS → FFT → detector de picos → MDC → frequência, além das interfaces CNN e inversor, permanece no `SMMA_Top`.

Com Icarus Verilog, a partir de `integration/RTL`:

```sh
iverilog -g2012 -s SMMA_Top -o smma_top.out -f filelist.f
```

O pipeline da árvore usa uma FFT de 64 pontos dedicada, pois precisa processar 32 quadros da janela decimada enquanto a cadeia espectral legada analisa janelas LMS separadas. A CNN existente é compartilhada entre o modo automático e o modo de pixels externos, sem instanciar um segundo classificador.

## Inserir os arquivos de `vibração/`

Os arquivos `.mat` não são uma memória de entrada que o FPGA consiga abrir em runtime. Eles são arquivos MATLAB para preparação offline/simulação. A leitura representativa de `4Nm_Normal.mat` encontrou:

- `Signal.y_values.values`: matriz `3072000 × 4` de `double`, com unidade `g`;
- `Signal.x_values.increment = 3.90625e-5 s`, portanto `fs = 25,600 Hz`;
- `Signal.function_record.primary_channel.label`: `Point1` a `Point4`;
- o canal Point1 do arquivo verificado teve pico de `9.58 g`.

Os arquivos `.mat` da pasta `vibração/` contêm sinais brutos, não as 12 features já calculadas. O exportador `integration/tools/export_vibration_mat.py` lê MATLAB v5 sem dependências externas e gera palavras `{sample_d[15:0], sample_x[15:0]}` em Q1.15, escala padrão `±32 g`. Ele atualiza tanto o HEX de simulação (`integration/data/`) quanto a ROM RTL (`integration/RTL/vetores/`). O exportador MATLAB também atualiza os dois arquivos. Para o caminho atual, `d` recebe a mesma amostra de `x`, pois o LMS original requer os dois sinais e não há um canal de referência especificado.

Exemplo usando Python padrão, a partir da raiz do repositório:

```powershell
python integration/tools/export_vibration_mat.py `
  vibração/4Nm_Normal.mat integration/data/vibration_input.hex `
  --channel 1 --full-scale-g 32 --samples 8503
```

O parâmetro `--samples 8503` exporta uma janela completa da árvore; use `--samples 0` para exportar todos os dados do arquivo. O canal selecionado é usado para `sample_x` e `sample_d`. O script informa a quantidade de amostras saturadas.

Também é possível usar o exportador MATLAB `integration/tools/export_vibration_mat.m`, passando `8503` como último argumento.

O arquivo `integration/data/vibration_input.hex` e a ROM `integration/RTL/vetores/vibration_input.hex` já contêm 8503 amostras do canal Point1 de `4Nm_Normal.mat`, em Q1.15. O testbench `RTL/tb_smma_dataset.v` aciona `dataset_start` e exercita a mesma fonte ROM RTL usada pelo top sintetizável. Compile e rode a partir de `integration/RTL`:

```sh
iverilog -g2012 -s tb_smma_dataset -o tb_smma.out -f filelist.f tb_smma_dataset.v
vvp tb_smma.out
```

O testbench reproduz a janela em modo rápido (`DATA_ROM_FAST=1`) e aguarda as saídas árvore/CNN. Para síntese, o padrão é `DATA_ROM_FAST=0` e a ROM fornece a taxa de 25,6 kHz. `analysis_done` sinaliza cada bloco de 64 amostras processado pela cadeia LMS/FFT/MDC/Frequência. No FPGA, o arquivo `.hex` inicializa a ROM; o `.mat` não é lido pelo hardware.

O `FFT_Top` do caminho legado analisa blocos de 64 saídas LMS e envia os bins ao detector de picos/MDC/frequência. A FFT dedicada da árvore alimenta tanto as features espectrais quanto o espectrograma 32×32 da CNN. As amostras `.mat` usam canais `Point1`–`Point4`; confirme qual canal físico corresponde ao eixo de vibração desejado antes de usar outros arquivos.
