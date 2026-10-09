# Fluxo Python do SMMA (treino, quantização e exportação)

O hardware faz só a **inferência**; tudo que precisa ser aprendido (pesos da CNN,
árvore de decisão, coeficientes do FIR) e todos os vetores de teste dos
testbenches são gerados aqui.

Documentação detalhada da CNN: **[docs/CNN_treinamento_e_RTL.md](../docs/CNN_treinamento_e_RTL.md)**.
Arquitetura do sistema: **[docs/ARQUITETURA.md](../docs/ARQUITETURA.md)**.

Saídas (caminhos em `config.py`):

| destino | o quê |
|---|---|
| `quartus/vetores/*.hex` | ROMs usadas na síntese e vetores dos testbenches |
| `RTL/cnn/CNN_Weight_ROM.v` | ROM dos pesos da CNN (passo 05) |
| `sim/golden/golden_model_cnn.py` | modelo bit-exato da CNN (passo 05) |

Comandos (a partir da raiz do repositório):

```bash
pip install -r python/requirements.txt
python python/scripts/01_converter_csv.py          # ja rodado
python python/scripts/02_gerar_espectrogramas.py   # ja rodado
python python/scripts/03_treinar.py                # ja rodado (16, 8 e 4 bits)
python python/scripts/04_avaliar_ponto_fixo.py     # ja rodado
python python/scripts/05_exportar_rtl.py           # ROM da CNN + vetores
python python/scripts/06_gerar_features.py         # 12 features de todas as janelas
python python/scripts/07_treinar_classificador.py  # arvore x SVM
python python/scripts/08_exportar_classificador.py # arvore.hex + clf_teste.hex
python python/scripts/09_exportar_frontend.py      # fir_coef.hex + fir_teste.hex
python python/scripts/10_exportar_demo_fpga.py     # 12 janelas da demonstracao
python python/scripts/11_exportar_vetores_features.py
./sim/run_regressao.sh                              # confere o hardware
```

> Regerar `arvore.hex` ou `demo_amostras.hex` muda o comportamento na placa; o
> `tb_Equivalencia` (que compara com a integração gravada na placa) passará a
> acusar diferença -- é esperado e deve ser feito conscientemente.
