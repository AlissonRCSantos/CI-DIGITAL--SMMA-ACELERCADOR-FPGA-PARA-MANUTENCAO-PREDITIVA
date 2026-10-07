function export_vibration_mat(matFile, hexFile, inputChannel, desiredChannel, fullScaleG, maxSamples)
% Exporta um .mat Test.Lab para palavras de simulacao {d[15:0], x[15:0]}.
% Uso (a partir da raiz do repositorio):
%   export_vibration_mat('vibração/4Nm_Normal.mat', ...
%       'integration/data/vibration_input.hex', 1, 1, 32, 64)
%
% inputChannel/desiredChannel sao indices 1..4 em Signal.y_values.values.
% desiredChannel=inputChannel usa o mesmo sinal como x(n) e d(n), adequado
% para exercitar o LMS como preditor quando nao ha canal de referencia definido.
% fullScaleG define a escala fixa comum: Q1.15 = aceleracao/fullScaleG.
% maxSamples=0 exporta o arquivo inteiro; o padrao 64 cria um quadro FFT.

    if nargin < 3 || isempty(inputChannel),  inputChannel = 1; end
    if nargin < 4 || isempty(desiredChannel), desiredChannel = inputChannel; end
    if nargin < 5 || isempty(fullScaleG), fullScaleG = 32; end
    if nargin < 6 || isempty(maxSamples), maxSamples = 64; end

    if inputChannel < 1 || inputChannel > 4 || inputChannel ~= fix(inputChannel)
        error('inputChannel deve ser um indice inteiro de 1 a 4.');
    end
    if desiredChannel < 1 || desiredChannel > 4 || desiredChannel ~= fix(desiredChannel)
        error('desiredChannel deve ser um indice inteiro de 1 a 4.');
    end
    if fullScaleG <= 0
        error('fullScaleG deve ser positivo.');
    end

    loaded = load(matFile, 'Signal');
    if ~isfield(loaded, 'Signal') || ~isfield(loaded.Signal, 'y_values') || ...
            ~isfield(loaded.Signal.y_values, 'values')
        error('O arquivo nao contem Signal.y_values.values.');
    end
    values = double(loaded.Signal.y_values.values);
    if size(values, 2) ~= 4
        error('Esperava quatro canais em Signal.y_values.values; encontrei %d.', size(values, 2));
    end

    count = size(values, 1);
    if maxSamples > 0
        count = min(count, floor(maxSamples));
    end
    x = values(1:count, inputChannel);
    d = values(1:count, desiredChannel);
    if any(~isfinite(x)) || any(~isfinite(d))
        error('Os canais selecionados contem NaN ou Inf.');
    end

    xClipCount = sum(abs(x) > fullScaleG);
    dClipCount = sum(abs(d) > fullScaleG);
    xq = int16(max(-32768, min(32767, round(x / fullScaleG * 32768))));
    dq = int16(max(-32768, min(32767, round(d / fullScaleG * 32768))));

    xBits = uint32(typecast(xq(:), 'uint16'));
    dBits = uint32(typecast(dq(:), 'uint16'));
    packed = bitor(bitshift(dBits, 16), xBits);

    outDir = fileparts(hexFile);
    if ~isempty(outDir) && ~isfolder(outDir)
        mkdir(outDir);
    end
    fid = fopen(hexFile, 'w');
    if fid < 0
        error('Nao foi possivel criar %s.', hexFile);
    end
    closeFile = onCleanup(@() fclose(fid));
    chunk = 65536;
    for first = 1:chunk:count
        last = min(first + chunk - 1, count);
        fprintf(fid, '%08X\n', packed(first:last));
    end

    dt = loaded.Signal.x_values.increment;
    fprintf('Amostras exportadas: %d\n', count);
    fprintf('Taxa de amostragem: %.6f Hz (dt=%.12g s)\n', 1 / dt, dt);
    fprintf('Canais: x=Point%d, d=Point%d; escala Q1.15=+/-%.6g g\n', ...
        inputChannel, desiredChannel, fullScaleG);
    fprintf('Saturacoes: x=%d, d=%d; arquivo=%s\n', xClipCount, dClipCount, hexFile);
end
