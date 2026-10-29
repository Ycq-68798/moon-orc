///|
/// A stripe location and row count in an ORC file.
pub(all) struct Stripe {
  offset : Int
  index_length : Int
  data_length : Int
  footer_length : Int
  rows : Int
}

///|
/// ORC type IDs follow the file's preorder schema, with the root at index 0.
pub(all) struct OrcType {
  kind : Int
  children : Array[Int]
  names : Array[String]
}

///|
pub struct OrcFile {
  bytes : Bytes
  compression : Int
  block_size : Int
  rows : Int
  stripes : Array[Stripe]
  types : Array[OrcType]
  decimal_precision : Array[Int]
  decimal_scale : Array[Int]
}

///|
fn parse_type(data : Bytes) -> OrcType raise OrcError {
  let fs = fields(data)
  let children = []
  let names = []
  for f in fs {
    if f.number == 2 && f.wire == 2 {
      let c = Cursor::{ data: f.bytes, pos: 0, }
      while c.pos < c.data.length() {
        children.push(checked_int(c.varint()))
      }
    } else if f.number == 2 && f.wire == 0 {
      children.push(checked_int(f.value))
    } else if f.number == 3 && f.wire == 2 {
      let name = @utf8.decode(f.bytes) catch {
        _ => raise Invalid("invalid UTF-8 in schema")
      }
      names.push(name)
    }
  }
  { kind: number(fs, 1, -1), children, names, }
}

///|
/// Parse an uncompressed, ZLIB- or Snappy-compressed ORC file from bytes.
pub fn open(data : Bytes) -> OrcFile raise OrcError {
  let len = data.length()
  if len < 4 || data[0] != b'O' || data[1] != b'R' || data[2] != b'C' {
    raise Invalid("missing ORC header")
  }
  let ps_len = data[len - 1].to_int()
  if ps_len == 0 || ps_len > len - 4 {
    raise Invalid("invalid postscript length")
  }
  let ps_start = len - 1 - ps_len
  let ps = fields(data[ps_start:len - 1].to_owned())
  let compression = number(ps, 2, 0)
  if compression != 0 && compression != 1 && compression != 2 {
    raise Invalid("unsupported compression codec")
  }
  let block_size = number(ps, 3, 262144)
  if compression != 0 && (block_size <= 0 || block_size > 8 * 1024 * 1024) {
    raise Invalid("invalid compression block size")
  }
  let footer_len = number(ps, 1, -1)
  if footer_len < 0 || footer_len > ps_start - 3 {
    raise Invalid("invalid footer length")
  }
  let footer_start = ps_start - footer_len
  let footer_data = decompress_stream(
    data[footer_start:ps_start].to_owned(),
    compression,
    block_size,
  )
  let footer = fields(footer_data)
  let stripes = []
  let types = []
  let decimal_precision = []
  let decimal_scale = []
  for f in footer {
    if f.number == 3 && f.wire == 2 {
      let s = fields(f.bytes)
      let stripe = Stripe::{
        offset: number(s, 1, -1),
        index_length: number(s, 2, -1),
        data_length: number(s, 3, -1),
        footer_length: number(s, 4, -1),
        rows: number(s, 5, -1),
      }
      if stripe.offset < 3 ||
        stripe.index_length < 0 ||
        stripe.data_length < 0 ||
        stripe.footer_length < 0 ||
        stripe.rows < 0 ||
        stripe.offset > footer_start ||
        stripe.index_length > footer_start - stripe.offset ||
        stripe.data_length > footer_start - stripe.offset - stripe.index_length ||
        stripe.footer_length >
        footer_start - stripe.offset - stripe.index_length - stripe.data_length {
        raise Invalid("invalid stripe range")
      }
      stripes.push(stripe)
    } else if f.number == 4 && f.wire == 2 {
      types.push(parse_type(f.bytes))
      let type_fields = fields(f.bytes)
      decimal_precision.push(number(type_fields, 5, -1))
      decimal_scale.push(number(type_fields, 6, -1))
    }
  }
  if types.length() == 0 || types[0].kind != 12 {
    raise Invalid("expected struct root")
  }
  let root = types[0]
  if root.names.length() != root.children.length() {
    raise Invalid("invalid root schema")
  }
  for child in root.children {
    if child <= 0 || child >= types.length() {
      raise Invalid("invalid root column id")
    }
  }
  for field in footer {
    if field.number == 10 {
      raise Invalid("encrypted files are not supported")
    }
  }
  let rows = number(footer, 6, 0)
  // Keep allocation bounded until a streaming API is available.
  if rows > 10000000 {
    raise Invalid("file exceeds 10 million row limit")
  }
  for stripe in stripes {
    if stripe.rows > rows {
      raise Invalid("invalid stripe row count")
    }
  }
  {
    bytes: data,
    compression,
    block_size,
    rows,
    stripes,
    types,
    decimal_precision,
    decimal_scale,
  }
}
