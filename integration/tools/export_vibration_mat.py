#!/usr/bin/env python3
"""Exporta Signal.y_values.values de MAT v5 para {d[15:0], x[15:0]} em Q1.15."""
import argparse
import math
import struct
from pathlib import Path


def element(data, pos, endian):
    tag = struct.unpack_from(endian + "I", data, pos)[0]
    small_size = tag >> 16
    small_type = tag & 0xFFFF
    if small_size:
        return small_type, data[pos + 4:pos + 4 + small_size], pos + 8
    kind, size = struct.unpack_from(endian + "II", data, pos)
    start = pos + 8
    return kind, data[start:start + size], start + ((size + 7) & ~7)


def decode_matrix(body, endian):
    pos = 0
    _, flags, pos = element(body, pos, endian)
    array_class = struct.unpack_from(endian + "I", flags)[0] & 0xFF
    _, dims_blob, pos = element(body, pos, endian)
    dims = struct.unpack(endian + "i" * (len(dims_blob) // 4), dims_blob)
    _, name_blob, pos = element(body, pos, endian)
    name = name_blob.rstrip(b"\0").decode("ascii", "replace")

    if array_class == 2:  # mxSTRUCT_CLASS
        _, field_len_blob, pos = element(body, pos, endian)
        field_len = struct.unpack_from(endian + "i", field_len_blob)[0]
        _, fields_blob, pos = element(body, pos, endian)
        names = [fields_blob[i:i + field_len].split(b"\0", 1)[0].decode("ascii")
                 for i in range(0, len(fields_blob), field_len)]
        count = math.prod(dims)
        structs = []
        for _ in range(count):
            item = {}
            for field in names:
                kind, value, next_pos = element(body, pos, endian)
                if kind != 14:
                    raise ValueError(f"campo {field} nao contem uma matriz MAT")
                item[field] = decode_matrix(value, endian)
                pos = next_pos
            structs.append(item)
        value = structs[0] if count == 1 else structs
    elif array_class == 1:  # mxCELL_CLASS
        values = []
        for _ in range(math.prod(dims)):
            kind, child, pos = element(body, pos, endian)
            values.append(decode_matrix(child, endian) if kind == 14 else None)
        value = values
    else:
        kind, raw, pos = element(body, pos, endian)
        value = (kind, dims, raw, endian)
    return {"name": name, "dims": dims, "value": value}


def read_mat(path):
    data = path.read_bytes()
    if not data.startswith(b"MATLAB 5.0 MAT-file"):
        raise ValueError("esperado arquivo MAT v5")
    endian = "<" if data[126:128] == b"IM" else ">"
    pos = 128
    while pos + 8 <= len(data):
        kind, body, pos = element(data, pos, endian)
        if kind == 14:
            decoded = decode_matrix(body, endian)
            if decoded["name"] == "Signal":
                return decoded["value"], endian
    raise ValueError("variavel Signal nao encontrada")


def as_struct(value, name):
    if not isinstance(value, dict) or name not in value:
        raise ValueError(f"campo {name} nao encontrado")
    return value[name]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mat_file", type=Path)
    parser.add_argument("hex_file", type=Path)
    parser.add_argument("--channel", type=int, default=1, help="canal Point1..Point4")
    parser.add_argument("--full-scale-g", type=float, default=32.0)
    parser.add_argument("--samples", type=int, default=8503, help="0 exporta o arquivo inteiro")
    args = parser.parse_args()
    if args.channel not in range(1, 5) or args.full_scale_g <= 0:
        parser.error("channel deve ser 1..4 e full-scale-g deve ser positivo")

    signal, endian = read_mat(args.mat_file)
    y_values = as_struct(signal, "y_values")
    numeric = as_struct(y_values, "values")
    kind, dims, raw, _ = numeric
    if kind != 9 or len(dims) != 2 or dims[1] != 4:
        raise ValueError(f"esperava matriz double Nx4; encontrei tipo={kind}, dims={dims}")
    total = dims[0]
    count = total if args.samples == 0 else min(total, args.samples)
    channel_offset = (args.channel - 1) * total
    out = []
    clipped = 0
    for i in range(count):
        value = struct.unpack_from(endian + "d", raw, 8 * (channel_offset + i))[0]
        if not math.isfinite(value):
            raise ValueError(f"amostra nao finita no indice {i}")
        clipped += abs(value) > args.full_scale_g
        q = max(-32768, min(32767, round(value / args.full_scale_g * 32768)))
        word = q & 0xFFFF
        out.append(f"{(word << 16) | word:08X}\n")

    content = "".join(out)
    args.hex_file.parent.mkdir(parents=True, exist_ok=True)
    args.hex_file.write_text(content, encoding="ascii")
    synth_rom = Path(__file__).resolve().parents[1] / "RTL" / "vetores" / "vibration_input.hex"
    if synth_rom.resolve() != args.hex_file.resolve():
        synth_rom.parent.mkdir(parents=True, exist_ok=True)
        synth_rom.write_text(content, encoding="ascii")
    print(f"{count} amostras; fs=25600 Hz; canal=Point{args.channel}; saturadas={clipped}")
    print(f"Saida: {args.hex_file}")
    print(f"ROM RTL: {synth_rom}")


if __name__ == "__main__":
    main()
