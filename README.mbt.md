# Moon ORC

A MoonBit reader for a deliberately limited, interoperable subset of Apache ORC. It parses an uncompressed, ZLIB-compressed or Snappy-compressed file's schema and stripe directory and projects named top-level integer, integer-list, string-list, string, binary, date, timestamp, decimal, boolean and floating-point columns, preserving nulls.

## Current support

- In-memory `Bytes` input; uncompressed, ZLIB-compressed or Snappy-compressed, unencrypted ORC. File and stripe metadata use protobuf.
- `BYTE` (signed 8-bit), `SHORT`, `INT`, and `LONG`, returned as nullable `Int64` values. Byte RLE and direct integer RLEv1 / RLEv2 are supported, including short repeat, direct, delta and patched base. Multiple stripes and all-null columns are supported.
- Top-level `LIST<BYTE>`, `LIST<SHORT>`, `LIST<INT>`, and `LIST<LONG>` via `read_int_list_column`, returning nullable lists of nullable `Int64` values. Null lists, empty lists and null elements are distinct. `LIST<STRING>` is available via `read_string_list_column` with direct and dictionary encoding; empty strings and strictly decoded UTF-8 text are preserved. At most 10 million total elements per projected list column are decoded across the file.
- `STRING`, `VARCHAR`, and `CHAR` with direct and dictionary encoding in ORC 0.11 and 0.12. Text is decoded as strict UTF-8 and returned as stored, including trailing spaces and an initial U+FEFF; CHAR padding and declared maximum length are not applied or enforced.
- `BINARY` returns nullable `Bytes` without UTF-8 conversion; empty bytes and null are distinct. `DATE` returns nullable `Int` as raw signed days since 1970-01-01 (UTC), limited to the signed 32-bit range. The file calendar is not parsed or converted; historical dates can differ from readers that convert between the hybrid Julian/Gregorian and proleptic Gregorian calendars.
- `TIMESTAMP` and `TIMESTAMP_INSTANT` return nullable `OrcTimestamp` values with separate floor seconds and nanoseconds (0–999,999,999). TIMESTAMP is a wall-clock value represented as seconds since 1970-01-01 as if UTC; it accepts only stripes whose writer timezone is UTC, GMT, Etc/UTC or Etc/GMT; a missing or other writer timezone is rejected. TIMESTAMP_INSTANT is a UTC instant and does not depend on the writer timezone. Fractional timestamps before 1970 and within the first second of 1970 are rejected because legacy producers can encode those values ambiguously; whole seconds before 1970 are supported back to 1582-10-15. Earlier timestamps are rejected because historical calendar conversion is not implemented. The exact 1582 cutoff has not been tested against an independent timestamp writer. Files with wrapped negative nanosecond values are rejected.
- `DECIMAL` with explicit schema precision 1–38 and scale 0–precision can be read with `read_decimal128_column`, returning nullable `OrcDecimal128` values. Its `unscaled` field is a canonical signed base-10 integer string and the exact value is `unscaled * 10^(-scale)`; zero is `"0"`, without leading zeros or a plus sign. The existing `read_decimal_column` returns `OrcDecimal` with an `Int64` coefficient for precision 1–18. Both APIs support ORC 0.11 and 0.12 direct encodings. Missing precision or scale, differing per-value scales, values beyond declared precision, and overflow are rejected; no rounding or rescaling is performed. Legacy files without explicit decimal precision are outside this subset.
- `BOOLEAN`, `FLOAT`, and `DOUBLE` as nullable `Bool`, `Float` and `Double`, respectively. IEEE-754 infinities, NaNs, signed zero and subnormal values are decoded; NaN payload and sign preservation are not guaranteed across backends.
- File size/offsets and row counts are currently limited to signed 32-bit values; row count is limited to 10 million while reading is in-memory.
- Zstandard and other compression codecs, other nested data types, predicate pushdown, writing and encrypted data are not implemented. RLEv2 patched-base runs with main width plus patch width above 64 bits and variable-delta runs with zero first delta are rejected. Unsupported or malformed cases return `OrcError`.

```moonbit nocheck
// Within a package that imports the module as @orc, obtain the bytes using
// the I/O facility of your application/backend.

///|
fn read_order_ids(bytes : Bytes) -> Array[Int64?] raise {
  let file = @orc.open(bytes)
  file.read_int_column("order_id")
}

///|
fn read_customer_names(bytes : Bytes) -> Array[String?] raise {
  let file = @orc.open(bytes)
  file.read_string_column("customer_name")
}
```

The MoonBit module is `Ycq-68798/moon-orc`. In a package that depends on this module, add the following to `moon.pkg`:

```moonbit nocheck
///|
import {
  "Ycq-68798/moon-orc" @orc,
}
```

The repository can be cloned to run its examples and tests.

## Verify

```shell
moon check --target all
moon test --target all
moon run cmd/main --target native -- sample.orc
```

The CLI reports the row count, stripe count and top-level schema of an uncompressed, ZLIB-compressed or Snappy-compressed ORC file. `sample.orc` is an Apache Arrow-generated fixture included in this repository. The executable uses `moonbitlang/x/fs`; the core reader accepts in-memory bytes and uses `mizchi/zlib` for DEFLATE and a MoonBit implementation for Snappy decompression. Snappy block sizes, literals and copy ranges are checked as each block is decoded. A compressed block may expand to at most 8 MiB, and a decompressed stream is limited to 64 MiB.

`interop_wbtest.mbt` contains files generated and independently read by Apache Arrow / PyArrow 26.0.0. They check signed 8/16/32/64-bit values, nulls, the minimum and maximum 64-bit integers, 20 stripes, projection, ZLIB- and Snappy-compressed footers and column streams, 300,000-row multi-block ZLIB files for ORC 0.11 and 0.12, every RLEv2 encoding, direct/dictionary string streams and binary/date/timestamp/decimal/boolean/float/double columns in both format versions, including ZLIB and Snappy with multiple stripes. Timestamp tests use PyArrow-generated files and include wall and instant values, nulls, nanosecond fractions after the first epoch second, whole seconds before 1970, and explicit rejection of Arrow-generated negative fractions and missing or unsupported writer timezones. Timestamp files produced by Java ORC or Hive have not yet been independently tested. Integer and STRING LIST tests cover both ORC versions, all four integer element types, direct and dictionary STRING streams, null and empty lists, null elements, integer boundaries, Unicode, multiple stripes, three compression modes, invalid UTF-8 and truncated, oversized or invalid dictionary streams. DECIMAL tests cover declared precision 1, 18 and 38, scales 0, 4, 18 and 38, nulls, signed 38-digit boundaries and mixed magnitudes, multiple stripes and rejected malformed streams or mismatched scales. BINARY tests include all 256 byte values, empty values and nulls; DATE tests cover negative and positive epoch days and signed 32-bit boundaries. Floating-point tests check bit patterns for non-NaN values and verify NaN classification; boolean and floating-point tests also reject truncated data and presence streams. Snappy tests also cover multiple compressed blocks and invalid block lengths, literals and copy offsets. STRING fixtures cover empty strings, nulls, all-null columns, Unicode, BOM and trailing spaces. Tests also use the Apache ORC specification examples and check truncated, overflowing and invalid patch streams. The VARCHAR and CHAR fixtures use STRING streams from Arrow with the schema type changed; Arrow reads them independently, but they are not generated by a native CHAR/VARCHAR writer. A synthetic long-gap patched-base ORC file is read independently by Arrow; its file statistics still describe the zero-filled source column, so it is used only to test decoding. CI also regenerates these fixtures in an isolated copy with Python 3.12 and `pyarrow==26.0.0`, checks them with PyArrow and runs the generated MoonBit tests on all four backends. It compares decoded values, not platform-specific encoded bytes. `sample.orc` and the embedded test fixtures can be regenerated with Python and `pyarrow==26.0.0`:

On Windows, timestamp fixture generation also requires the `tzdata` Python package unless `TZDIR` points to an IANA timezone database.

```shell
python generate_fixtures.py
moon test --target all
```

With PyArrow 26.0.0, the following writer/reader round trip returned `1024` at position 510 rather than the original `1000000000` on the test machine. The test suite therefore uses the independently read synthetic long-gap fixture described above for this boundary:

```python
import pyarrow as pa
import pyarrow.orc as orc
v = [1000000000 if i in (3, 510) else 1000 + (i * 17) % 32 for i in range(512)]
b = pa.BufferOutputStream()
orc.write_table(pa.table({"x": pa.array(v, type=pa.int64())}), b, file_version="0.12", compression="uncompressed")
print(orc.read_table(pa.BufferReader(b.getvalue())).column("x")[510].as_py())
```

Reference: [Apache ORC specification](https://orc.apache.org/specification/ORCv1/).
