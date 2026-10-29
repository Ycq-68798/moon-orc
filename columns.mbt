///|
priv struct Stream {
  kind : Int
  column : Int
  offset : Int
  length : Int
}

///|
fn byte_rle(data : Bytes, limit : Int) -> Array[Int] raise OrcError {
  let c = Cursor::{ data, pos: 0, }
  let out = []
  while c.pos < data.length() {
    let h = c.byte()
    if h < 128 {
      let n = h + 3
      let v = c.byte()
      if n > limit - out.length() {
        raise Invalid("byte RLE exceeds expected size")
      }
      for _ in 0..<n {
        out.push(v)
      }
    } else {
      let n = 256 - h
      if n > limit - out.length() {
        raise Invalid("byte RLE exceeds expected size")
      }
      for _ in 0..<n {
        out.push(c.byte())
      }
    }
  }
  out
}

///|
fn bits(data : Bytes, count : Int) -> Array[Bool] raise OrcError {
  let packed = byte_rle(data, (count + 7) / 8)
  if packed.length() != (count + 7) / 8 {
    raise Invalid("incorrect bit stream length")
  }
  [
    for i in 0..<count => (packed[i / 8] & (128 >> (i % 8))) != 0
  ]
}

///|
fn zigzag(n : UInt64) -> Int64 {
  let magnitude = (n >> 1).reinterpret_as_int64()
  if (n & 1UL) == 0UL {
    magnitude
  } else {
    -magnitude - 1L
  }
}

///|
fn int_rle(data : Bytes, count : Int) -> Array[Int64] raise OrcError {
  let c = Cursor::{ data, pos: 0, }
  let out = []
  while c.pos < data.length() {
    let h = c.byte()
    let n = if h < 128 { h + 3 } else { 256 - h }
    if n > count - out.length() {
      raise Invalid("integer RLE exceeds expected size")
    }
    if h < 128 {
      let raw_delta = c.byte()
      let delta = Int64::from_int(
        if raw_delta >= 128 {
          raw_delta - 256
        } else {
          raw_delta
        },
      )
      let start = zigzag(c.varint())
      for i in 0..<n {
        let diff = delta * Int64::from_int(i)
        if (diff > 0L && start > 9223372036854775807L - diff) ||
          (diff < 0L && start < -9223372036854775808L - diff) {
          raise Invalid("integer RLE overflows Int64")
        }
        out.push(start + diff)
      }
    } else {
      for _ in 0..<n {
        out.push(zigzag(c.varint()))
      }
    }
  }
  if out.length() != count {
    raise Invalid("incorrect integer stream length")
  }
  out
}

///|
fn streams(
  file : OrcFile,
  stripe : Stripe,
) -> (Array[Stream], Array[Int]) raise OrcError {
  let start = stripe.offset + stripe.index_length + stripe.data_length
  let footer = decompress_stream(
    file.bytes[start:start + stripe.footer_length].to_owned(),
    file.compression,
    file.block_size,
  )
  let sf = fields(footer)
  let result = []
  let encodings = []
  let mut offset = stripe.offset
  for f in sf {
    if f.number == 1 && f.wire == 2 {
      let parts = fields(f.bytes)
      let length = number(parts, 3, -1)
      if length < 0 || offset > start || length > start - offset {
        raise Invalid("invalid stream range")
      }
      result.push({
        kind: number(parts, 1, -1),
        column: number(parts, 2, 0),
        offset,
        length,
      })
      offset += length
    } else if f.number == 2 && f.wire == 2 {
      encodings.push(number(fields(f.bytes), 1, -1))
    } else if f.number == 4 {
      raise Invalid("encrypted stripes are not supported")
    }
  }
  if offset != start {
    raise Invalid("stripe stream lengths do not match")
  }
  (result, encodings)
}

///|
fn get_stream(
  file : OrcFile,
  streams : Array[Stream],
  column : Int,
  kind : Int,
) -> Bytes? raise OrcError {
  for s in streams {
    if s.column == column && s.kind == kind {
      let raw = file.bytes[s.offset:s.offset + s.length].to_owned()
      return Some(decompress_stream(raw, file.compression, file.block_size))
    }
  }
  None
}

///|
/// Read a top-level integer column as nullable signed 64-bit values. ORC 0.11
/// direct RLEv1 is supported, along with byte columns in ORC 0.12.
pub fn OrcFile::read_int_column(
  file : OrcFile,
  name : String,
) -> Array[Int64?] raise OrcError {
  let root = file.types[0]
  if root.names.length() != root.children.length() {
    raise Invalid("invalid root schema")
  }
  let mut column = -1
  for i in 0..<root.names.length() {
    if root.names[i] == name {
      column = root.children[i]
      break
    }
  }
  if column <= 0 || column >= file.types.length() {
    raise Invalid("column not found")
  }
  let kind = file.types[column].kind
  if kind < 1 || kind > 4 {
    raise Invalid("column is not an integer type")
  }
  let out = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() {
      raise Invalid("missing column encoding")
    }
    if (kind != 1 && encodings[column] != 0) ||
      (kind == 1 && encodings[column] != 0 && encodings[column] != 2) {
      raise Invalid("unsupported integer column encoding")
    }
    let present = match get_stream(file, ss, column, 0) {
      Some(data) => bits(data, stripe.rows)
      None => [ for _ in 0..<stripe.rows => true ]
    }
    let mut count = 0
    for p in present {
      if p {
        count += 1
      }
    }
    let data = get_stream(file, ss, column, 1).unwrap_or(b"")
    let values = if kind == 1 {
      let raw = byte_rle(data, count)
      if raw.length() != count {
        raise Invalid("incorrect byte stream length")
      }
      [
        for v in raw => Int64::from_int(if v >= 128 { v - 256 } else { v })
      ]
    } else {
      int_rle(data, count)
    }
    let mut value_index = 0
    for p in present {
      if p {
        out.push(Some(values[value_index]))
        value_index += 1
      } else {
        out.push(None)
      }
    }
  }
  if out.length() != file.rows {
    raise Invalid("stripe row count does not match footer")
  }
  out
}
