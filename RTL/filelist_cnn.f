// ============================================================================
// filelist_cnn.f -- lista de arquivos do acelerador CNN do SMMA
// Uso com Cadence Xcelium:
//     ./run_sim_cnn.sh -c tb_CNN_Top
// ============================================================================

// ---- RTL: blocos aritmeticos basicos ----
CNN_MAC_Unit.v
CNN_ReLU.v

// ---- RTL: memoria de pesos ----
CNN_Weight_ROM.v

// ---- RTL: camadas da rede ----
CNN_Line_Buffer.v
CNN_Conv_Layer.v
CNN_MaxPool.v
CNN_Dense_Classifier.v

// ---- RTL: controle e integracao ----
CNN_Control_FSM.v
CNN_Top.v

// ---- Testbenches ----
tb_CNN_MAC_Unit.v
tb_CNN_ReLU.v
tb_CNN_Weight_ROM.v
tb_CNN_Line_Buffer.v
tb_CNN_Conv_Layer.v
tb_CNN_MaxPool.v
tb_CNN_Dense_Classifier.v
tb_CNN_Control_FSM.v
tb_CNN_Top.v
