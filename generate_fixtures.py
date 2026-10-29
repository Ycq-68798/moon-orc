from pathlib import Path
import pyarrow as pa
import pyarrow.orc as orc

root = Path(__file__).parent
values = [0, -1, 7, None, -128, 127, 22, -35, None, 4, 5, 6, 7, 8, 9]
table = pa.table({
    'tiny': pa.array(values, type=pa.int8()),
    'small': pa.array(values, type=pa.int16()),
    'big': pa.array([0, -1, 2**40, None, -(2**40), 2**63-1, -(2**63), 42, None, 1, 2, 3, 4, 5, 6], type=pa.int64()),
    'empty': pa.array([None] * len(values), type=pa.int32()),
})
multi_values = [i % 11 - 5 if i % 7 else None for i in range(5000)]
multi_table = pa.table({'x': pa.array(multi_values, type=pa.int32())})

def encode(table, **options):
    sink = pa.BufferOutputStream()
    orc.write_table(table, sink, **options)
    data = sink.getvalue().to_pybytes()
    assert orc.read_table(pa.BufferReader(data)).equals(table)
    return data

def literal(data):
    return '[' + ', '.join(f'0x{b:02x}' for b in data) + ']'

def expected(values):
    return '[' + ', '.join('None' if v is None else f'Some({v}L)' for v in values) + ']'

v11 = encode(table, compression='uncompressed', file_version='0.11')
v12 = encode(table, compression='uncompressed', file_version='0.12')
zlib = encode(table, compression='zlib', file_version='0.11')
zlib12 = encode(table, compression='zlib', file_version='0.12')
snappy = encode(table, compression='snappy', file_version='0.11')
multi_options = dict(file_version='0.11', stripe_size=128, batch_size=256)
multi = encode(multi_table, compression='uncompressed', **multi_options)
zvalues = [i % 11 - 5 if i % 7 else None for i in range(300000)]
ztable = pa.table({'x': pa.array(zvalues, type=pa.int32())})
zlib_multi = encode(ztable, compression='zlib', file_version='0.11', compression_block_size=65536)
zlib_v12_large = encode(ztable, compression='zlib', file_version='0.12', compression_block_size=65536)
assert orc.ORCFile(pa.BufferReader(multi)).nstripes > 1
cases = {
    'short': ([7] * 5, 0),
    'direct': ([(i * 104729) % 20001 - 10000 for i in range(100)], 1),
    'fixed': (list(range(100)), 3),
    'increasing': ([i * i for i in range(100)], 3),
    'decreasing': ([-i * i for i in range(100)], 3),
    'patch': ([1000000 if i == 50 else 1000 + (i * 17) % 32 for i in range(200)], 2),
    'negative_patch': ([1000000 if i == 50 else -1000 + (i * 17) % 32 for i in range(200)], 2),
    'negative_short': ([-7] * 5, 0),
    'direct64': ([-(2**63), 2**63-1, 0, -1, 1, 12], 1),
}
case_files = {name: encode(pa.table({'x': pa.array(values, type=pa.int64())}), compression='uncompressed', file_version='0.12') for name, (values, _) in cases.items()}

# Hand-build one RLEv2 stream for a 512-row ORC container produced by Arrow.
# Its two patches are 507 positions apart, requiring the 255-gap continuation.
# Arrow reads this synthetic file independently; its file statistics still
# describe the original zero-filled column, so it is used only for decoding.
def _varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)

def _fields(data):
    pos = 0
    result = []
    def read_varint():
        nonlocal pos
        value = shift = 0
        while True:
            b = data[pos]
            pos += 1
            value |= (b & 127) << shift
            shift += 7
            if not b & 128:
                return value
    while pos < len(data):
        tag = read_varint()
        number, wire = tag >> 3, tag & 7
        if wire == 0:
            value = read_varint()
        elif wire == 2:
            length = read_varint()
            value = data[pos:pos + length]
            pos += length
        elif wire in (1, 5):
            length = 8 if wire == 1 else 4
            value = data[pos:pos + length]
            pos += length
        else:
            raise ValueError(f'unsupported protobuf wire {wire}')
        result.append([number, wire, value])
    return result

def _emit(fields):
    result = bytearray()
    for number, wire, value in fields:
        result += _varint((number << 3) | wire)
        if wire == 0:
            result += _varint(value)
        elif wire == 2:
            result += _varint(len(value)) + value
        else:
            result += value
    return bytes(result)

def _get(fields, number):
    return next(field[2] for field in fields if field[0] == number)

def _put(fields, number, value):
    next(field for field in fields if field[0] == number)[2] = value

def long_gap_fixture():
    data = encode(pa.table({'x': pa.array([0] * 512, type=pa.int64())}), compression='uncompressed', file_version='0.12')
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    stripe = _fields(_get(footer, 3))
    offset, index_length, data_length, stripe_footer_length = (_get(stripe, n) for n in (1, 2, 3, 4))
    stripe_footer_start = offset + index_length + data_length
    stripe_footer = _fields(data[stripe_footer_start:stripe_footer_start + stripe_footer_length])
    # Three 9-bit patch words: (gap=3, patch=1), (gap=255, patch=0),
    # (gap=252, patch=1). Main data has 512 zero 1-bit offsets.
    patch_words = ((7 << 18) | (510 << 9) | 505) << 5
    replacement = bytes([0x81, 0xff, 0x00, 0xe3, 0x00]) + bytes(64) + patch_words.to_bytes(4, 'big')
    source = offset
    parts = []
    for field in stripe_footer:
        if field[0] == 1:
            descriptor = _fields(field[2])
            length = _get(descriptor, 3)
            payload = data[source:source + length]
            source += length
            if _get(descriptor, 1) == 1 and _get(descriptor, 2) == 1:
                payload = replacement
                _put(descriptor, 3, len(payload))
                field[2] = _emit(descriptor)
            parts.append(payload)
    body = b''.join(parts)
    new_stripe_footer = _emit(stripe_footer)
    _put(stripe, 3, len(body) - index_length)
    _put(stripe, 4, len(new_stripe_footer))
    _put(footer, 3, _emit(stripe))
    _put(footer, 2, offset + len(body) + len(new_stripe_footer))
    new_footer = _emit(footer)
    _put(ps, 1, len(new_footer))
    new_ps = _emit(ps)
    rebuilt = (data[:offset] + body + new_stripe_footer +
               data[stripe_footer_start + stripe_footer_length:footer_start] +
               new_footer + new_ps + bytes([len(new_ps)]))
    actual = orc.read_table(pa.BufferReader(rebuilt)).column('x').to_pylist()
    expected_values = [2 if i in (3, 510) else 0 for i in range(512)]
    assert actual == expected_values
    return rebuilt

long_gap = long_gap_fixture()


out = '// Generated by generate_fixtures.py using Apache Arrow; do not hand-edit.\n'
for name, data in [('fixture_11', v11), ('fixture_12', v12), ('fixture_zlib', zlib), ('fixture_zlib12', zlib12), ('fixture_long_gap', long_gap), ('fixture_snappy', snappy), ('fixture_multi', multi), ('fixture_zlib_multi', zlib_multi), ('fixture_zlib_v12_large', zlib_v12_large)]:
    out += f'\n///|\nfn {name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in case_files.items():
    out += f'\n///|\nfn fixture_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for test_name, fixture in [('Apache Arrow ORC 0.11 integers', 'fixture_11'), ('Apache Arrow ZLIB compressed integers', 'fixture_zlib'), ('Apache Arrow ORC 0.12 integers', 'fixture_12'), ('Apache Arrow ORC 0.12 ZLIB integers', 'fixture_zlib12')]:
    out += f'\n///|\ntest "{test_name}" {{\n  let file = open({fixture}())\n  assert_eq(file.rows, 15)\n  assert_eq(file.stripes.length(), 1)\n  assert_eq(file.types[0].names, ["tiny", "small", "big", "empty"])\n'
    for col in table.column_names:
        out += f'  assert_eq(file.read_int_column("{col}"), {expected(table[col].to_pylist())})\n'
    out += '}\n'
out += """
///|
test \"reject invalid file\" {
  let bad = try open(b\"bad\") catch { Invalid(_) => true } noraise { _ => false }
  let unsupported_codec = try open(fixture_snappy()) catch { Invalid(_) => true } noraise { _ => false }
  assert_true(bad && unsupported_codec)
}
"""
out += """
///|
test "Long-gap patched-base fixture independently read by Arrow" {
  let file = open(fixture_long_gap())
  let (ss, _) = streams(file, file.stripes[0])
  let raw = get_stream(file, ss, 1, 1).unwrap()
  assert_eq(raw[0].to_int() >> 6, 2)
  let values = file.read_int_column("x")
  for i in 0..<512 {
    assert_eq(values[i], if i == 3 || i == 510 { Some(2L) } else { Some(0L) })
  }
}
"""
for name, (case_values, kind) in cases.items():
    out += f"""
///|
test \"Apache Arrow RLEv2 {name}\" {{
  let file = open(fixture_{name}())
  let (ss, _) = streams(file, file.stripes[0])
  let raw = get_stream(file, ss, 1, 1).unwrap()
  assert_eq(raw[0].to_int() >> 6, {kind})
  assert_eq(file.read_int_column(\"x\"), {expected(case_values)})
}}
"""
for test_name, fixture, row_count in [('Apache Arrow multi-stripe projection', 'fixture_multi', 5000), ('Apache Arrow ZLIB large projection', 'fixture_zlib_multi', 300000), ('Apache Arrow ZLIB ORC 0.12 large projection', 'fixture_zlib_v12_large', 300000)]:
    out += f'''\n///|
test "{test_name}" {{
  let file = open({fixture}())
  assert_eq(file.rows, {row_count})
  assert_true(file.stripes.length() > 0)
  let result = file.read_int_column("x")
  for i in 0..<{row_count} {{
    let expected = if i % 7 == 0 {{ None }} else {{ Some(Int64::from_int(i % 11 - 5)) }}
    assert_eq(result[i], expected)
  }}
}}
'''
(root / 'interop_wbtest.mbt').write_text(out, encoding='utf-8')
(root / 'sample.orc').write_bytes(v11)
print(f'Arrow {pa.__version__}: 0.11={len(v11)}, 0.12={len(v12)}, zlib={len(zlib)}, zlib-multi={len(zlib_multi)}')


