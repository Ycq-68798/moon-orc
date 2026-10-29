from pathlib import Path
import os
import sys
# Apache ORC C++ needs an IANA timezone database even for GMT on Windows.
if sys.platform == 'win32' and not os.environ.get('TZDIR'):
    try:
        import tzdata
    except ImportError as exc:
        raise RuntimeError('Install tzdata or set TZDIR to an IANA zoneinfo directory') from exc
    os.environ['TZDIR'] = str(Path(tzdata.__file__).parent / 'zoneinfo')
import json
from decimal import Decimal
import math
import struct
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
    return '[\n    ' + ',\n    '.join(', '.join(f'0x{b:02x}' for b in data[i:i+16]) for i in range(0, len(data), 16)) + ',\n  ]'

def expected(values):
    return '[' + ', '.join('None' if v is None else f'Some({v}L)' for v in values) + ']'

v11 = encode(table, compression='uncompressed', file_version='0.11')
v12 = encode(table, compression='uncompressed', file_version='0.12')
zlib = encode(table, compression='zlib', file_version='0.11')
zlib12 = encode(table, compression='zlib', file_version='0.12')
snappy = encode(table, compression='snappy', file_version='0.11')
snappy12 = encode(table, compression='snappy', file_version='0.12')
zstd = encode(table, compression='zstd', file_version='0.11')
multi_options = dict(file_version='0.11', stripe_size=128, batch_size=256)
multi = encode(multi_table, compression='uncompressed', **multi_options)
zvalues = [i % 11 - 5 if i % 7 else None for i in range(300000)]
ztable = pa.table({'x': pa.array(zvalues, type=pa.int32())})
zlib_multi = encode(ztable, compression='zlib', file_version='0.11', compression_block_size=65536)
zlib_v12_large = encode(ztable, compression='zlib', file_version='0.12', compression_block_size=65536)
snappy_v12_large = encode(ztable, compression='snappy', file_version='0.12', compression_block_size=65536)
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

text_values = ["", None, "MoonBit", "中文", "🍉", "MoonBit", "x", "", " end  ", "\ufeffliteral"] * 2
text_table = pa.table({'text': pa.array(text_values, type=pa.string()), 'all_null': pa.array([None] * len(text_values), type=pa.string())})
text_cases = {}
for version in ('0.11', '0.12'):
    for dictionary in (False, True):
        key = ('v11' if version == '0.11' else 'v12') + ('_dict' if dictionary else '_direct')
        text_cases[key] = encode(text_table, compression='uncompressed', file_version=version, dictionary_key_size_threshold=1.0 if dictionary else 0.0)
text_cases['v12_dict_zlib'] = encode(text_table, compression='zlib', file_version='0.12', dictionary_key_size_threshold=1.0)
text_multi_values = [None if i % 7 == 0 else f'值-{i % 17}-🍉' for i in range(5000)]
text_multi_table = pa.table({'text': pa.array(text_multi_values, type=pa.string())})
text_cases['multi'] = encode(text_multi_table, compression='uncompressed', file_version='0.12', stripe_size=128, batch_size=256, dictionary_key_size_threshold=1.0)
text_cases['multi_snappy'] = encode(text_multi_table, compression='snappy', file_version='0.12', stripe_size=128, batch_size=256, dictionary_key_size_threshold=1.0)
text_cases['multi_zlib'] = encode(text_multi_table, compression='zlib', file_version='0.12', stripe_size=128, batch_size=256, dictionary_key_size_threshold=1.0)
for name in ('multi', 'multi_zlib', 'multi_snappy'):
    assert orc.ORCFile(pa.BufferReader(text_cases[name])).nstripes > 1

# Arrow maps CHAR / VARCHAR to string when reading, but cannot write them.
# Change the Type kind in an Arrow-written STRING file while leaving streams
# intact, then independently verify Arrow's output before generating the test.
def with_string_kind(data, kind):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    types = [field for field in footer if field[0] == 4]
    column_type = _fields(types[1][2])
    _put(column_type, 1, kind)
    column_type.append([4, 0, 100])
    types[1][2] = _emit(column_type)
    new_footer = _emit(footer)
    _put(ps, 1, len(new_footer))
    new_ps = _emit(ps)
    return data[:footer_start] + new_footer + new_ps + bytes([len(new_ps)])

for name, kind, source in [('varchar', 16, 'v12_direct'), ('char', 17, 'v12_direct'), ('varchar_dict', 16, 'v12_dict'), ('char_dict', 17, 'v12_dict')]:
    fixture = with_string_kind(text_cases[source], kind)
    actual = orc.read_table(pa.BufferReader(fixture)).column('text').to_pylist()
    assert actual == text_values
    text_cases[name] = fixture

# Corrupt bytes in the DATA stream without modifying lengths. These fixtures
# exercise public reader error handling; they are not claimed to be valid ORC.
def corrupt_data_stream(data, fill_all=False):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    stripe = _fields(_get(footer, 3))
    offset = _get(stripe, 1)
    stripe_footer_start = offset + _get(stripe, 2) + _get(stripe, 3)
    stripe_footer = _fields(data[stripe_footer_start:stripe_footer_start + _get(stripe, 4)])
    result = bytearray(data)
    source = offset
    for field in stripe_footer:
        if field[0] == 1:
            desc = _fields(field[2])
            length = _get(desc, 3)
            if _get(desc, 1) == 1 and _get(desc, 2) == 1:
                assert length > 0
                if fill_all:
                    result[source:source + length] = bytes([255]) * length
                else:
                    result[source] = 255
                return bytes(result)
            source += length
    raise AssertionError('DATA stream not found')

text_cases['bad_utf8'] = corrupt_data_stream(text_cases['v12_direct'])
text_cases['bad_dictionary_index'] = corrupt_data_stream(text_cases['v12_dict'], fill_all=True)



flags = [True, False, None, True, False, True, False, None, True, False, True, False]
float_values = [0.0, -0.0, 1.5, -2.25, float('inf'), float('-inf'), float('nan'), None, 2**-149, 3.4028234663852886e38, 0.5, -1.0]
double_values = [0.0, -0.0, 1.5, -2.25, float('inf'), float('-inf'), float('nan'), None, 2**-1074, 1.7976931348623157e308, 0.5, -1.0]
primitive_table = pa.table({
    'flag': pa.array(flags, type=pa.bool_()),
    'f': pa.array(float_values, type=pa.float32()),
    'd': pa.array(double_values, type=pa.float64()),
    'empty_bool': pa.array([None] * len(flags), type=pa.bool_()),
    'empty_float': pa.array([None] * len(flags), type=pa.float32()),
    'empty_double': pa.array([None] * len(flags), type=pa.float64()),
})
def float_bits(v, bits):
    return int.from_bytes(struct.pack('<f' if bits == 32 else '<d', v), 'little')
def check_primitives(table, actual):
    assert actual.column('flag').to_pylist() == table.column('flag').to_pylist()
    for col, width in [('f', 32), ('d', 64)]:
        for x, y in zip(table.column(col).to_pylist(), actual.column(col).to_pylist()):
            if x is None:
                assert y is None
            elif math.isnan(x):
                assert math.isnan(y)
            else:
                assert float_bits(x, width) == float_bits(y, width)
    for col in ('empty_bool', 'empty_float', 'empty_double'):
        assert actual.column(col).to_pylist() == table.column(col).to_pylist()

primitive_cases = {}
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        sink = pa.BufferOutputStream()
        orc.write_table(primitive_table, sink, compression=codec, file_version=version)
        data = sink.getvalue().to_pybytes()
        check_primitives(primitive_table, orc.read_table(pa.BufferReader(data)))
        primitive_cases['v' + version.replace('.', '') + '_' + codec] = data
primitive_multi_table = pa.table({
    'flag': pa.array([None if i % 7 == 0 else i % 2 == 0 for i in range(2000)], type=pa.bool_()),
    'f': pa.array([None if i % 11 == 0 else (i % 17 - 8) * 0.5 for i in range(2000)], type=pa.float32()),
    'd': pa.array([None if i % 13 == 0 else (i % 31 - 15) * 0.125 for i in range(2000)], type=pa.float64()),
})
for codec in ('uncompressed', 'zlib', 'snappy'):
    sink = pa.BufferOutputStream()
    source = primitive_multi_table
    if codec != 'uncompressed':
        source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
    orc.write_table(source, sink, compression=codec, file_version='0.12', stripe_size=128, batch_size=256)
    data = sink.getvalue().to_pybytes()
    assert orc.read_table(pa.BufferReader(data)).equals(source)
    assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
    primitive_cases['multi_' + codec] = data


# Truncate selected stream while rebuilding lengths so public readers must
# reject the malformed stream rather than failing only on file framing.
def rewrite_primitive_stream(data, column, stream_kind, transform):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    stripe = _fields(_get(footer, 3))
    offset, index_length, data_length, stripe_footer_length = (_get(stripe, n) for n in (1, 2, 3, 4))
    sf_start = offset + index_length + data_length
    stripe_footer = _fields(data[sf_start:sf_start + stripe_footer_length])
    source = offset
    parts = []
    found = False
    for field in stripe_footer:
        if field[0] == 1:
            desc = _fields(field[2])
            length = _get(desc, 3)
            payload = data[source:source + length]
            source += length
            if _get(desc, 1) == stream_kind and _get(desc, 2) == column:
                assert length > 0
                payload = transform(payload)
                _put(desc, 3, len(payload))
                field[2] = _emit(desc)
                found = True
            parts.append(payload)
    assert found
    body = b''.join(parts)
    new_sf = _emit(stripe_footer)
    _put(stripe, 3, len(body) - index_length)
    _put(stripe, 4, len(new_sf))
    _put(footer, 3, _emit(stripe))
    _put(footer, 2, offset + len(body) + len(new_sf))
    new_footer = _emit(footer)
    _put(ps, 1, len(new_footer))
    new_ps = _emit(ps)
    return (data[:offset] + body + new_sf + data[sf_start + stripe_footer_length:footer_start] + new_footer + new_ps + bytes([len(new_ps)]))

def truncate_primitive_stream(data, column, stream_kind):
    return rewrite_primitive_stream(data, column, stream_kind, lambda payload: payload[:-1])

bad_primitive_cases = {
    'bool_data': truncate_primitive_stream(primitive_cases['v012_uncompressed'], 1, 1),
    'bool_present': truncate_primitive_stream(primitive_cases['v012_uncompressed'], 1, 0),
    'float_data': truncate_primitive_stream(primitive_cases['v012_uncompressed'], 2, 1),
    'double_data': truncate_primitive_stream(primitive_cases['v012_uncompressed'], 3, 1),
}

# BINARY stores bytes verbatim. DATE is a signed count of epoch days.
binary_items = [b'\x00\xff', b'', None, bytes(range(256)), b'hello', b'\x80\x00', b'xyz', None]
date_items = [-2147483648, 2147483647, 0, -1, 1, 19782, None, -25567]
binary_date_table = pa.table({
    'bin': pa.array(binary_items, type=pa.binary()),
    'date': pa.array(date_items, type=pa.date32()),
    'empty_bin': pa.array([None] * len(binary_items), type=pa.binary()),
    'empty_date': pa.array([None] * len(date_items), type=pa.date32()),
})
binary_date_cases = {}
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        binary_date_cases['v' + version.replace('.', '') + '_' + codec] = encode(binary_date_table, compression=codec, file_version=version)
        result = orc.read_table(pa.BufferReader(binary_date_cases['v' + version.replace('.', '') + '_' + codec]))
        assert result.column('date').cast(pa.int32()).to_pylist() == date_items
        assert result.column('bin').to_pylist() == binary_items
binary_date_multi = pa.table({
    'bin': pa.array([None if i % 7 == 0 else bytes([0, 255, i % 251]) for i in range(2000)], type=pa.binary()),
    'date': pa.array([None if i % 11 == 0 else i - 1000 for i in range(2000)], type=pa.date32()),
})
for codec in ('uncompressed', 'zlib', 'snappy'):
    source = binary_date_multi
    if codec != 'uncompressed':
        source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
    data = encode(source, compression=codec, file_version='0.12', stripe_size=128, batch_size=256)
    assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
    binary_date_cases['multi_' + codec] = data
bad_binary_date_cases = {
    'binary_data': truncate_primitive_stream(binary_date_cases['v012_uncompressed'], 1, 1),
    'binary_length': truncate_primitive_stream(binary_date_cases['v012_uncompressed'], 1, 2),
    'binary_present': truncate_primitive_stream(binary_date_cases['v012_uncompressed'], 1, 0),
    'date_data': truncate_primitive_stream(binary_date_cases['v012_uncompressed'], 2, 1),
    'date_present': truncate_primitive_stream(binary_date_cases['v012_uncompressed'], 2, 0),
}
# Re-label an int64 column with an out-of-int32 value as DATE, to exercise
# rejection of a structurally valid but out-of-range DATE stream.
bad_int = encode(pa.table({'bad_date': pa.array([2147483648], type=pa.int64())}), compression='uncompressed', file_version='0.12')
ps_start = len(bad_int) - 1 - bad_int[-1]
ps = _fields(bad_int[ps_start:-1])
footer_start = ps_start - _get(ps, 1)
footer = _fields(bad_int[footer_start:ps_start])
types = [field for field in footer if field[0] == 4]
column_type = _fields(types[1][2])
_put(column_type, 1, 15)
types[1][2] = _emit(column_type)
new_footer = _emit(footer)
_put(ps, 1, len(new_footer))
new_ps = _emit(ps)
bad_binary_date_cases['date_range'] = bad_int[:footer_start] + new_footer + new_ps + bytes([len(new_ps)])


# Arrow writes timezone-naive TIMESTAMP and timezone-aware TIMESTAMP_INSTANT.
timestamp_values = [-9223372036000000000, -2000000000, -1000000000, 0, 1000000001, 1999999999, 1420070400000000000, 1420070400000000001, 9223372036854775807, None]
timestamp_table = pa.table({
    'wall': pa.array(timestamp_values, type=pa.timestamp('ns')),
    'instant': pa.array(timestamp_values, type=pa.timestamp('ns', tz='Asia/Shanghai')),
    'empty_wall': pa.array([None] * len(timestamp_values), type=pa.timestamp('ns')),
    'empty_instant': pa.array([None] * len(timestamp_values), type=pa.timestamp('ns', tz='UTC')),
})
timestamp_cases = {}
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        sink = pa.BufferOutputStream()
        orc.write_table(timestamp_table, sink, compression=codec, file_version=version)
        data = sink.getvalue().to_pybytes()
        result = orc.read_table(pa.BufferReader(data))
        for column in ('wall', 'instant'):
            assert result.column(column).cast(pa.int64()).to_pylist() == timestamp_values
        for column in ('empty_wall', 'empty_instant'):
            assert result.column(column).null_count == len(timestamp_values)
        timestamp_cases['v' + version.replace('.', '') + '_' + codec] = data
multi_ts_values = [None if i % 7 == 0 else (i - 1000) * 1000000000 + ((i % 5) * 123456789 if i > 1000 else 0) for i in range(2000)]
timestamp_multi_table = pa.table({
    'wall': pa.array(multi_ts_values, type=pa.timestamp('ns')),
    'instant': pa.array(multi_ts_values, type=pa.timestamp('ns', tz='UTC')),
})
for codec in ('uncompressed', 'zlib', 'snappy'):
    sink = pa.BufferOutputStream()
    source = timestamp_multi_table
    if codec != 'uncompressed':
        source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
    orc.write_table(source, sink, compression=codec, file_version='0.12', stripe_size=128, batch_size=256)
    data = sink.getvalue().to_pybytes()
    result = orc.read_table(pa.BufferReader(data))
    for column in ('wall', 'instant'):
        assert result.column(column).cast(pa.int64()).to_pylist() == multi_ts_values
    assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
    timestamp_cases['multi_' + codec] = data
negative_fraction_values = [-1000000001, -1000000, -1, None]
negative_fraction_table = pa.table({
    'wall': pa.array(negative_fraction_values, type=pa.timestamp('ns')),
    'instant': pa.array(negative_fraction_values, type=pa.timestamp('ns', tz='UTC')),
})
negative_fraction_cases = {}
for version in ('0.11', '0.12'):
    data = encode(negative_fraction_table, compression='uncompressed', file_version=version)
    result = orc.read_table(pa.BufferReader(data))
    for col in ('wall', 'instant'):
        assert result.column(col).cast(pa.int64()).to_pylist() == negative_fraction_values
    negative_fraction_cases['v' + version.replace('.', '')] = data
def rewrite_timestamp_zone(data, zone):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    stripe = _fields(_get(footer, 3))
    offset, ilen, dlen, slen = (_get(stripe, n) for n in (1, 2, 3, 4))
    start = offset + ilen + dlen
    sf = _fields(data[start:start + slen])
    if zone is None:
        sf = [f for f in sf if f[0] != 3]
    else:
        _put(sf, 3, zone)
    new_sf = _emit(sf)
    _put(stripe, 4, len(new_sf))
    _put(footer, 3, _emit(stripe))
    _put(footer, 2, start + len(new_sf))
    new_footer = _emit(footer)
    _put(ps, 1, len(new_footer))
    new_ps = _emit(ps)
    return data[:start] + new_sf + data[start + slen:footer_start] + new_footer + new_ps + bytes([len(new_ps)])

bad_timestamp_cases = {
    'seconds': truncate_primitive_stream(timestamp_cases['v012_uncompressed'], 1, 1),
    'nanos': truncate_primitive_stream(timestamp_cases['v012_uncompressed'], 1, 5),
    'present': truncate_primitive_stream(timestamp_cases['v012_uncompressed'], 1, 0),
    'non_utc': rewrite_timestamp_zone(timestamp_cases['v012_uncompressed'], b'America/New_York'),
    'missing_zone': rewrite_timestamp_zone(timestamp_cases['v012_uncompressed'], None),
    'epoch_fraction': encode(pa.table({'wall': pa.array([1], type=pa.timestamp('ns'))}), compression='uncompressed', file_version='0.12'),
}
# DECIMAL fixtures preserve declared scale and exact values across both formats.
decimal_values = [Decimal('-99999999999999.9999'), Decimal('-1.0001'), Decimal('0.0000'), Decimal('0.0001'), Decimal('99999999999999.9999'), None]
decimal_table = pa.table({
    'amount': pa.array(decimal_values, type=pa.decimal128(18, 4)),
    'all_null': pa.array([None] * len(decimal_values), type=pa.decimal128(8, 2)),
    'wide': pa.array([Decimal('-' + '9' * 38), Decimal('-1'), Decimal('0'), Decimal('1'), Decimal('9' * 38), None], type=pa.decimal128(38, 0)),
    'wide_frac': pa.array([Decimal('-0.' + '9' * 38), Decimal('-0.' + '0' * 37 + '1'), Decimal('0'), Decimal('0.' + '0' * 37 + '1'), Decimal('0.' + '9' * 38), None], type=pa.decimal128(38, 38)),
    'wide_varied': pa.array([Decimal('-10000000000000000000000000000000000000'), Decimal('-987654321098765432109876543210'), Decimal('-1234567890123456789'), Decimal('1234567890123456789'), Decimal('12345678901234567890123456789012345678'), None], type=pa.decimal128(38, 0)),
    'small': pa.array([Decimal('-9'), Decimal('-1'), Decimal('0'), Decimal('1'), Decimal('9'), None], type=pa.decimal128(1, 0)),
    'frac': pa.array([Decimal('-0.999999999999999999'), Decimal('-0.1'), Decimal('0'), Decimal('0.1'), Decimal('0.999999999999999999'), None], type=pa.decimal128(18, 18)),
})
decimal_cases = {}
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        data = encode(decimal_table, compression=codec, file_version=version)
        result = orc.read_table(pa.BufferReader(data))
        assert result.column('amount').to_pylist() == decimal_values
        assert result.column('all_null').null_count == len(decimal_values)
        for name in ('small', 'frac', 'wide', 'wide_frac', 'wide_varied'):
            assert result.column(name).to_pylist() == decimal_table.column(name).to_pylist()
        decimal_cases['v' + version.replace('.', '') + '_' + codec] = data
multi_decimal_values = [None if i % 7 == 0 else Decimal(i - 1000).scaleb(-4) for i in range(2000)]
multi_wide_values = [None if i % 7 == 0 else Decimal(('-' if i % 2 else '') + '9' * 38) for i in range(2000)]
decimal_multi_table = pa.table({'amount': pa.array(multi_decimal_values, type=pa.decimal128(18, 4)), 'wide': pa.array(multi_wide_values, type=pa.decimal128(38, 0))})
for codec in ('uncompressed', 'zlib', 'snappy'):
    source = decimal_multi_table
    if codec != 'uncompressed':
        source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
    data = encode(source, compression=codec, file_version='0.12', stripe_size=128, batch_size=256)
    assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
    assert orc.read_table(pa.BufferReader(data)).column('amount').to_pylist() == multi_decimal_values
    assert orc.read_table(pa.BufferReader(data)).column('wide').to_pylist() == multi_wide_values
    decimal_cases['multi_' + codec] = data
def rewrite_decimal_schema(data, precision, scale):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    footer = _fields(data[footer_start:ps_start])
    schema_field = [field for field in footer if field[0] == 4][1]
    schema = _fields(schema_field[2])
    if precision is None:
        schema = [field for field in schema if field[0] != 5]
    else:
        _put(schema, 5, precision)
    if scale is None:
        schema = [field for field in schema if field[0] != 6]
    else:
        _put(schema, 6, scale)
    schema_field[2] = _emit(schema)
    new_footer = _emit(footer)
    _put(ps, 1, len(new_footer))
    new_ps = _emit(ps)
    return data[:footer_start] + new_footer + new_ps + bytes([len(new_ps)])

bad_decimal_cases = {
    'data': truncate_primitive_stream(decimal_cases['v012_uncompressed'], 1, 1),
    'scale': truncate_primitive_stream(decimal_cases['v012_uncompressed'], 1, 5),
    'present': truncate_primitive_stream(decimal_cases['v012_uncompressed'], 1, 0),
    'precision': rewrite_decimal_schema(decimal_cases['v012_uncompressed'], 2, 1),
    'scale_mismatch': rewrite_decimal_schema(decimal_cases['v012_uncompressed'], 18, 3),
    'bad_schema': rewrite_decimal_schema(decimal_cases['v012_uncompressed'], 2, 3),
    'missing_precision': rewrite_decimal_schema(decimal_cases['v012_uncompressed'], None, 4),
    'missing_scale': rewrite_decimal_schema(decimal_cases['v012_uncompressed'], 18, None),
    'overflow': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 1, 1, lambda data: b'\xff' * 10 + data),
    'trailing': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 1, 1, lambda data: data + b'\x00'),
    'wide_precision': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 3, 1, lambda data: _varint(2 * 10**38)),
    'wide_negative_precision': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 3, 1, lambda data: _varint(2 * 10**38 - 1)),
    'wide_overflow': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 3, 1, lambda data: b'\x80' * 18 + b'\x04'),
    'wide_truncated': rewrite_primitive_stream(decimal_cases['v012_uncompressed'], 3, 1, lambda data: b'\x80'),
}
# Lists preserve null lists, empty lists and nullable integer elements.
list_bounds = {'tiny': (-128, 127, pa.int8()), 'small': (-32768, 32767, pa.int16()), 'int': (-(2**31), 2**31 - 1, pa.int32()), 'big': (-(2**63), 2**63 - 1, pa.int64())}
list_arrays = {}
for name, (lo, hi, typ) in list_bounds.items():
    list_arrays[name] = pa.array([None, [], [None], [0, -1, None, 1], [lo, hi], [None, None]], type=pa.list_(typ))
list_arrays['all_null'] = pa.array([None] * 6, type=pa.list_(pa.int64()))
list_arrays['text'] = pa.array([['a'], None, [], ['b'], ['c'], []], type=pa.list_(pa.string()))
list_table = pa.table(list_arrays)
list_cases = {}
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        data = encode(list_table, compression=codec, file_version=version)
        assert orc.read_table(pa.BufferReader(data)).equals(list_table)
        list_cases['v' + version.replace('.', '') + '_' + codec] = data
multi_list_values = [None if i % 4 == 0 else [] if i % 4 == 1 else [None, i, -i] if i % 4 == 2 else [-(2**63), 2**63 - 1] for i in range(2000)]
list_multi_table = pa.table({'numbers': pa.array(multi_list_values, type=pa.list_(pa.int64()))})
for codec in ('uncompressed', 'zlib', 'snappy'):
    source = list_multi_table
    if codec != 'uncompressed':
        source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
    data = encode(source, compression=codec, file_version='0.12', stripe_size=128, batch_size=256)
    assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
    assert orc.read_table(pa.BufferReader(data)).column('numbers').to_pylist() == multi_list_values
    list_cases['multi_' + codec] = data
data = encode(list_multi_table, compression='uncompressed', file_version='0.11', stripe_size=128, batch_size=256)
assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
assert orc.read_table(pa.BufferReader(data)).column('numbers').to_pylist() == multi_list_values
list_cases['multi_v011'] = data
bad_list_cases = {
    'parent_present': truncate_primitive_stream(list_cases['v011_uncompressed'], 1, 0),
    'length': truncate_primitive_stream(list_cases['v011_uncompressed'], 1, 2),
    'child_present': truncate_primitive_stream(list_cases['v011_uncompressed'], 2, 0),
    'child_data': truncate_primitive_stream(list_cases['v011_uncompressed'], 2, 1),
    'too_many': rewrite_primitive_stream(list_cases['v011_uncompressed'], 1, 2, lambda data: bytes([251]) + b''.join(_varint(x) for x in (10000001, 0, 0, 0, 0))),
}
# LIST<STRING> includes null parents, empty values, UTF-8, and null elements.
string_list_rows = [None, [], ['', None, '中文', '🍉', '\ufeff', 'x '], ['重复', '重复', None], [None, None], ['', 'MoonBit']]
string_list_values = string_list_rows * 40
string_list_table = pa.table({'text': pa.array(string_list_values, type=pa.list_(pa.string())), 'all_null': pa.array([None] * len(string_list_values), type=pa.list_(pa.string()))})
string_list_cases = {}
def child_encoding_uncompressed(data, child):
    ps_start = len(data) - 1 - data[-1]
    ps = _fields(data[ps_start:-1])
    footer_start = ps_start - _get(ps, 1)
    stripe = _fields(_get(_fields(data[footer_start:ps_start]), 3))
    offset, ilen, dlen, slen = (_get(stripe, n) for n in (1, 2, 3, 4))
    stripe_footer = _fields(data[offset + ilen + dlen:offset + ilen + dlen + slen])
    columns = [field[2] for field in stripe_footer if field[0] == 2]
    return _get(_fields(columns[child]), 1)
for version in ('0.11', '0.12'):
    for codec in ('uncompressed', 'zlib', 'snappy'):
        for label, threshold in (('direct', 0.0), ('dict', 1.0)):
            data = encode(string_list_table, compression=codec, file_version=version, dictionary_key_size_threshold=threshold)
            assert orc.read_table(pa.BufferReader(data)).equals(string_list_table)
            if codec == 'uncompressed':
                assert child_encoding_uncompressed(data, 2) == (0 if label == 'direct' else 1) + (2 if version == '0.12' else 0)
            string_list_cases['v' + version.replace('.', '') + '_' + codec + '_' + label] = data
multi_string_list_values = [None if i % 4 == 0 else [] if i % 4 == 1 else [None, '', '中文', '🍉'] if i % 4 == 2 else ['MoonBit', 'MoonBit', 'x '] for i in range(2000)]
string_list_multi_table = pa.table({'text': pa.array(multi_string_list_values, type=pa.list_(pa.string()))})
for version, codec in [('0.11', 'uncompressed'), ('0.12', 'uncompressed'), ('0.12', 'zlib'), ('0.12', 'snappy')]:
    for label, threshold in (('direct', 0.0), ('dict', 1.0)):
        source = string_list_multi_table
        if codec != 'uncompressed':
            source = source.append_column('pad', pa.array([str(i) + ':' + 'x' * 64 for i in range(2000)]))
        data = encode(source, compression=codec, file_version=version, stripe_size=128, batch_size=256, dictionary_key_size_threshold=threshold)
        assert orc.ORCFile(pa.BufferReader(data)).nstripes > 1
        assert orc.read_table(pa.BufferReader(data)).column('text').to_pylist() == multi_string_list_values
        string_list_cases['multi_v' + version.replace('.', '') + '_' + codec + '_' + label] = data
bad_string_list_cases = {
    'parent_present': truncate_primitive_stream(string_list_cases['v011_uncompressed_direct'], 1, 0),
    'parent_length': truncate_primitive_stream(string_list_cases['v011_uncompressed_direct'], 1, 2),
    'child_present': truncate_primitive_stream(string_list_cases['v011_uncompressed_direct'], 2, 0),
    'child_data': truncate_primitive_stream(string_list_cases['v011_uncompressed_direct'], 2, 1),
    'child_length': truncate_primitive_stream(string_list_cases['v011_uncompressed_direct'], 2, 2),
    'dict_ids': truncate_primitive_stream(string_list_cases['v011_uncompressed_dict'], 2, 1),
    'dict_data': truncate_primitive_stream(string_list_cases['v011_uncompressed_dict'], 2, 3),
    'invalid_utf8': rewrite_primitive_stream(string_list_cases['v011_uncompressed_direct'], 2, 1, lambda data: b'\xff' + data[1:]),
    'dict_invalid_utf8': rewrite_primitive_stream(string_list_cases['v011_uncompressed_dict'], 2, 3, lambda data: b'\xff' + data[1:]),
    'dict_index': rewrite_primitive_stream(string_list_cases['v011_uncompressed_dict'], 2, 1, lambda data: (bytes([127, 0]) + _varint(999)) * 2 + bytes([97, 0]) + _varint(999)),
    'too_many': rewrite_primitive_stream(string_list_cases['v011_uncompressed_direct'], 1, 2, lambda data: bytes([255]) + _varint(10000001) + bytes([127, 0, 0, 66, 0, 0])),
}
out = '// Generated by generate_fixtures.py using Apache Arrow; do not hand-edit.\n'
for name, data in [('fixture_11', v11), ('fixture_12', v12), ('fixture_zlib', zlib), ('fixture_zlib12', zlib12), ('fixture_long_gap', long_gap), ('fixture_snappy', snappy), ('fixture_snappy12', snappy12), ('fixture_zstd', zstd), ('fixture_multi', multi), ('fixture_zlib_multi', zlib_multi), ('fixture_zlib_v12_large', zlib_v12_large), ('fixture_snappy_v12_large', snappy_v12_large)]:
    out += f'\n///|\nfn {name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in string_list_cases.items():
    out += f'\n///|\nfn fixture_string_list_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'
for name, data in bad_string_list_cases.items():
    out += f'\n///|\nfn fixture_bad_string_list_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in list_cases.items():
    out += f'\n///|\nfn fixture_list_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'
for name, data in bad_list_cases.items():
    out += f'\n///|\nfn fixture_bad_list_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in decimal_cases.items():
    out += f'\n///|\nfn fixture_decimal_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'
for name, data in bad_decimal_cases.items():
    out += f'\n///|\nfn fixture_bad_decimal_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in timestamp_cases.items():
    out += f'\n///|\nfn fixture_timestamp_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in negative_fraction_cases.items():
    out += f'\n///|\nfn fixture_negative_timestamp_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'
for name, data in bad_timestamp_cases.items():
    out += f'\n///|\nfn fixture_bad_timestamp_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in binary_date_cases.items():
    out += f'\n///|\nfn fixture_binary_date_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'
for name, data in bad_binary_date_cases.items():
    out += f'\n///|\nfn fixture_binary_date_bad_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in bad_primitive_cases.items():
    out += f'\n///|\nfn fixture_primitive_bad_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in primitive_cases.items():
    out += f'\n///|\nfn fixture_primitive_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in text_cases.items():
    out += f'\n///|\nfn fixture_text_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for name, data in case_files.items():
    out += f'\n///|\nfn fixture_{name}() -> Bytes {{\n  {literal(data)}\n}}\n'

for test_name, fixture in [('Apache Arrow ORC 0.11 integers', 'fixture_11'), ('Apache Arrow ZLIB compressed integers', 'fixture_zlib'), ('Apache Arrow Snappy ORC 0.11 integers', 'fixture_snappy'), ('Apache Arrow Snappy ORC 0.12 integers', 'fixture_snappy12'), ('Apache Arrow ORC 0.12 integers', 'fixture_12'), ('Apache Arrow ORC 0.12 ZLIB integers', 'fixture_zlib12')]:
    out += f'\n///|\ntest "{test_name}" {{\n  let file = open({fixture}())\n  assert_eq(file.rows, 15)\n  assert_eq(file.stripes.length(), 1)\n  assert_eq(file.types[0].names, ["tiny", "small", "big", "empty"])\n'
    for col in table.column_names:
        out += f'  assert_eq(file.read_int_column("{col}"), {expected(table[col].to_pylist())})\n'
    out += '}\n'
out += """
///|
test \"reject invalid file\" {
  let bad = try open(b\"bad\") catch { Invalid(_) => true } noraise { _ => false }
  let unsupported_codec = try open(fixture_zstd()) catch { Invalid(_) => true } noraise { _ => false }
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
for name, encoding in [('v11_direct', 0), ('v11_dict', 1), ('v12_direct', 2), ('v12_dict', 3), ('v12_dict_zlib', 3), ('varchar', 2), ('char', 2), ('varchar_dict', 3), ('char_dict', 3)]:
    expected_text = '[' + ', '.join('None' if v is None else 'Some(' + json.dumps(v, ensure_ascii=False) + ')' for v in text_values) + ']'
    out += f"""
///|
test \"Apache Arrow string {name}\" {{
  let file = open(fixture_text_{name}())
  let (_, encodings) = streams(file, file.stripes[0])
  assert_eq(encodings[1].kind, {encoding})
  assert_eq(file.read_string_column(\"text\"), {expected_text})
  assert_eq(file.read_string_column(\"all_null\"), [for _ in 0..<{len(text_values)} => None])
}}
"""
out += """
///|
test "reject corrupted string files" {
  let direct = open(fixture_text_bad_utf8())
  let dictionary = open(fixture_text_bad_dictionary_index())
  let bad_utf8 = try direct.read_string_column("text") catch { Invalid(_) => true } noraise { _ => false }
  let bad_dict = try dictionary.read_string_column("text") catch { Invalid(_) => true } noraise { _ => false }
  let bad_type = try direct.read_int_column("text") catch { Invalid(_) => true } noraise { _ => false }
  assert_true(bad_utf8 && bad_dict && bad_type)
}
"""
for suffix in ('multi', 'multi_zlib', 'multi_snappy'):
    out += f"""
///|
test \"Apache Arrow {suffix} string projection\" {{
  let file = open(fixture_text_{suffix}())
  assert_true(file.stripes.length() > 1)
  let result = file.read_string_column(\"text\")
  for i in 0..<5000 {{
    let expected = if i % 7 == 0 {{ None }} else {{ Some(\"值-\\{{i % 17}}-🍉\") }}
    assert_eq(result[i], expected)
  }}
}}
"""
out += """
///|
test "reject truncated primitive streams" {
  let a = open(fixture_primitive_bad_bool_data())
  let b = open(fixture_primitive_bad_bool_present())
  let c = open(fixture_primitive_bad_float_data())
  let d = open(fixture_primitive_bad_double_data())
  let bad_bool = try a.read_bool_column("flag") catch { Invalid(_) => true } noraise { _ => false }
  let bad_present = try b.read_bool_column("flag") catch { Invalid(_) => true } noraise { _ => false }
  let bad_float = try c.read_float_column("f") catch { Invalid(_) => true } noraise { _ => false }
  let bad_double = try d.read_double_column("d") catch { Invalid(_) => true } noraise { _ => false }
  let bad_type = try d.read_double_column("f") catch { Invalid(_) => true } noraise { _ => false }
  let missing = try d.read_bool_column("missing") catch { Invalid(_) => true } noraise { _ => false }
  assert_true(bad_bool && bad_present && bad_float && bad_double && bad_type && missing)
}
"""
for name in timestamp_cases:
    if name.startswith('multi_'):
        out += f"""
///|
test \"Apache Arrow timestamp {name}\" {{
  let file = open(fixture_timestamp_{name}())
  assert_true(file.stripes.length() > 1)
  let wall = file.read_timestamp_column(\"wall\")
  let instant = file.read_timestamp_instant_column(\"instant\")
  for i in 0..<2000 {{
    if i % 7 == 0 {{ assert_true(wall[i] is None); assert_true(instant[i] is None) }} else {{
      match wall[i] {{ Some(value) => {{ assert_eq(value.seconds, Int64::from_int(i - 1000)); assert_eq(value.nanosecond, if i > 1000 {{ (i % 5) * 123456789 }} else {{ 0 }}) }}; None => fail(\"expected wall timestamp\") }}
      match instant[i] {{ Some(value) => {{ assert_eq(value.seconds, Int64::from_int(i - 1000)); assert_eq(value.nanosecond, if i > 1000 {{ (i % 5) * 123456789 }} else {{ 0 }}) }}; None => fail(\"expected instant timestamp\") }}
    }}
  }}
}}
"""
        continue
    out += f"""
///|
test \"Apache Arrow timestamp {name}\" {{
  let file = open(fixture_timestamp_{name}())
  let wall = file.read_timestamp_column(\"wall\")
  let instant = file.read_timestamp_instant_column(\"instant\")
  let empty_wall = file.read_timestamp_column(\"empty_wall\")
  let empty_instant = file.read_timestamp_instant_column(\"empty_instant\")
  assert_true(empty_wall[0] is None && empty_instant[0] is None)
"""
    for i, val in enumerate(timestamp_values):
        if val is None:
            out += f'  assert_true(wall[{i}] is None && instant[{i}] is None)\n'
        else:
            sec, nanos = divmod(val, 1000000000)
            for column in ('wall', 'instant'):
                out += f'  match {column}[{i}] {{ Some(value) => {{ assert_eq(value.seconds, {sec}L); assert_eq(value.nanosecond, {nanos}) }}; None => fail(\"expected timestamp\") }}\n'
    out += '}\n'
for name in binary_date_cases:
    if name.startswith('multi_'):
        out += f"""
///|
test \"Apache Arrow BINARY DATE {name}\" {{
  let file = open(fixture_binary_date_{name}())
  assert_true(file.stripes.length() > 1)
  let binary = file.read_binary_column(\"bin\")
  let dates = file.read_date_column(\"date\")
  for i in 0..<2000 {{
    let expected_bin : Bytes? = if i % 7 == 0 {{ None }} else {{ Some([0, 255, (i % 251).to_byte()]) }}
    assert_eq(binary[i], expected_bin)
    assert_eq(dates[i], if i % 11 == 0 {{ None }} else {{ Some(i - 1000) }})
  }}
}}
"""
    else:
        expected_binary = '[' + ', '.join('None' if x is None else 'Some(b\"\")' if len(x) == 0 else 'Some(' + literal(x) + ')' for x in binary_items) + ']'
        expected_dates = '[' + ', '.join('None' if x is None else f'Some({x})' for x in date_items) + ']'
        out += f"""
///|
test \"Apache Arrow BINARY DATE {name}\" {{
  let file = open(fixture_binary_date_{name}())
  assert_eq(file.read_binary_column(\"bin\"), {expected_binary})
  assert_eq(file.read_date_column(\"date\"), {expected_dates})
  assert_eq(file.read_binary_column(\"empty_bin\"), [for _ in 0..<8 => None])
  assert_eq(file.read_date_column(\"empty_date\"), [for _ in 0..<8 => None])
}}
"""
out += """
///|
test "reject invalid BINARY and DATE files" {
  let a = open(fixture_binary_date_bad_binary_data())
  let b = open(fixture_binary_date_bad_binary_length())
  let c = open(fixture_binary_date_bad_binary_present())
  let d = open(fixture_binary_date_bad_date_data())
  let e = open(fixture_binary_date_bad_date_present())
  let f = open(fixture_binary_date_bad_date_range())
  let bad_data = try a.read_binary_column("bin") catch { Invalid(_) => true } noraise { _ => false }
  let bad_length = try b.read_binary_column("bin") catch { Invalid(_) => true } noraise { _ => false }
  let bad_presence = try c.read_binary_column("bin") catch { Invalid(_) => true } noraise { _ => false }
  let bad_date = try d.read_date_column("date") catch { Invalid(_) => true } noraise { _ => false }
  let bad_date_presence = try e.read_date_column("date") catch { Invalid(_) => true } noraise { _ => false }
  let bad_date_range = try f.read_date_column("bad_date") catch { Invalid(_) => true } noraise { _ => false }
  let wrong_type = try a.read_binary_column("date") catch { Invalid(_) => true } noraise { _ => false }
  assert_true(bad_data && bad_length && bad_presence && bad_date && bad_date_presence && bad_date_range && wrong_type)
}
"""
for name in primitive_cases:
    if name.startswith('multi_'):
        out += f"""
///|
test \"Apache Arrow primitive {name}\" {{
  let file = open(fixture_primitive_{name}())
  assert_true(file.stripes.length() > 1)
  let flags = file.read_bool_column(\"flag\")
  let floats = file.read_float_column(\"f\")
  let doubles = file.read_double_column(\"d\")
  for i in 0..<2000 {{
    assert_eq(flags[i], if i % 7 == 0 {{ None }} else {{ Some(i % 2 == 0) }})
    assert_eq(floats[i], if i % 11 == 0 {{ None }} else {{ Some(Float::from_int(i % 17 - 8) * (0.5 : Float)) }})
    assert_eq(doubles[i], if i % 13 == 0 {{ None }} else {{ Some(Double::from_int(i % 31 - 15) * 0.125) }})
  }}
}}
"""
        continue
    expected_flags = '[' + ', '.join('None' if x is None else 'Some(true)' if x else 'Some(false)' for x in flags) + ']'
    out += f"""
///|
test \"Apache Arrow primitive {name}\" {{
  let file = open(fixture_primitive_{name}())
  assert_eq(file.read_bool_column(\"flag\"), {expected_flags})
  assert_eq(file.read_bool_column(\"empty_bool\"), [for _ in 0..<12 => None])
  assert_eq(file.read_float_column(\"empty_float\"), [for _ in 0..<12 => None])
  assert_eq(file.read_double_column(\"empty_double\"), [for _ in 0..<12 => None])
  let floats = file.read_float_column(\"f\")
  let doubles = file.read_double_column(\"d\")
"""
    for col, values, width in [('floats', float_values, 32), ('doubles', double_values, 64)]:
        for i, val in enumerate(values):
            if val is None:
                out += f'  assert_true({col}[{i}] is None)\n'
            elif math.isnan(val):
                out += f'  match {col}[{i}] {{ Some(value) => assert_true(value.is_nan()); None => fail(\"expected NaN\") }}\n'
            else:
                literal_bits = f'0x{float_bits(val, width):x}' + ('U' if width == 32 else 'UL')
                method = 'reinterpret_as_uint' if width == 32 else 'reinterpret_as_uint64'
                out += f'  match {col}[{i}] {{ Some(value) => assert_eq(value.{method}(), {literal_bits}); None => fail("expected value") }}\n' 
    out += '}\n'
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
for test_name, fixture, row_count in [('Apache Arrow multi-stripe projection', 'fixture_multi', 5000), ('Apache Arrow ZLIB large projection', 'fixture_zlib_multi', 300000), ('Apache Arrow ZLIB ORC 0.12 large projection', 'fixture_zlib_v12_large', 300000), ('Apache Arrow Snappy ORC 0.12 large projection', 'fixture_snappy_v12_large', 300000)]:
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



