# Treinamento da CNN do SMMA

A documentação completa (como rodar, o que já foi rodado e a lógica do
treinamento) está no **[README principal do repositório](../README.md)**,
seções 3, 6 e 7.

Resumo dos comandos (a partir da raiz do repositório):

```bash
pip install -r python/requirements.txt
python python/scripts/01_converter_csv.py          # ja rodado
python python/scripts/02_gerar_espectrogramas.py   # ja rodado
python python/scripts/03_treinar.py                # ja rodado (16, 8 e 4 bits)
python python/scripts/04_avaliar_ponto_fixo.py     # ja rodado
python python/scripts/05_exportar_rtl.py           # ja rodado
cd RTL && ./run_all_cnn.sh                         # para testar
```
