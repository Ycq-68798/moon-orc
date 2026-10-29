# Moon ORC

A MoonBit reader for a deliberately limited, interoperable subset of Apache ORC. It parses an uncompressed file's schema and stripe directory and projects a named top-level integer column, preserving nulls.

## Current support

- In-memory `Bytes` input; uncompressed, unencrypted ORC only. File and stripe metadata use protobuf.
- `BYTE` (signed 8-bit), `SHORT`, `INT`, and `LONG`, returned as nullable `Int64` values. Byte RLE is supported for ORC 0.11 and 0.12; other integers require direct RLEv1 (ORC 0.11). Multiple stripes and all-null columns are supported.
- File size/offsets and row counts are currently limited to signed 32-bit values; row count is limited to 10 million while reading is in-memory.
- Zlib/Snappy and other compression, RLEv2 integers, strings, nested data, predicate pushdown, writing and encrypted data are not implemented. Unsupported cases return `OrcError`.

```moonbit nocheck
// Within a package that imports the module as @orc, obtain the bytes using
// the I/O facility of your application/backend.

///|
fn read_order_ids(bytes : Bytes) -> Array[Int64?] raise {
  let file = @orc.open(bytes)
  file.read_int_column("order_id")
}
```

The MoonBit module is `Ycq-68798/moon-orc`. In a package that depends on this module, add the following to `moon.pkg`:

```moonbit
import {
  "Ycq-68798/moon-orc" @orc,
}
```

The project has not yet been published to Mooncakes; the repository can be cloned to run its examples and tests.

## Verify

```shell
moon check --target all
moon test --target all
moon run cmd/main --target native -- sample.orc
```

The CLI reports the row count, stripe count and top-level schema of an uncompressed ORC file. `sample.orc` is an Apache Arrow-generated fixture included in this repository. The executable uses `moonbitlang/x/fs`; the core reader accepts in-memory bytes.

`interop_wbtest.mbt` contains files generated and independently read by Apache Arrow / PyArrow 26.0.0. They check signed 8/16/32/64-bit values, nulls, the minimum and maximum 64-bit integers, 20 stripes, projection, and rejection of compression and unsupported RLEv2. `sample.orc` and the embedded test fixtures can be regenerated with Python and `pyarrow==26.0.0`:

```shell
python generate_fixtures.py
moon test --target all
```

Reference: [Apache ORC specification](https://orc.apache.org/specification/ORCv1/).
