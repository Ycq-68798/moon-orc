///|
fn primitive_column(
  file : OrcFile,
  name : String,
  expected_kind : Int,
) -> Int raise OrcError {
  let root = file.types[0]
  if root.names.length() != root.children.length() {
    raise Invalid("invalid root schema")
  }
  for i in 0..<root.names.length() {
    if root.names[i] == name {
      let id = root.children[i]
      if id <= 0 || id >= file.types.length() {
        raise Invalid("invalid column id")
      }
      if file.types[id].kind != expected_kind {
        raise Invalid("column has a different type")
      }
      return id
    }
  }
  raise Invalid("column not found")
}

///|
fn primitive_stripe(
  file : OrcFile,
  stripe : Stripe,
  column : Int,
) -> (Array[Bool], Bytes) raise OrcError {
  let (ss, encodings) = streams(file, stripe)
  if column >= encodings.length() {
    raise Invalid("missing column encoding")
  }
  if encodings[column].kind != 0 && encodings[column].kind != 2 {
    raise Invalid("unsupported primitive encoding")
  }
  let present = match get_stream(file, ss, column, 0) {
    Some(data) => bits(data, stripe.rows)
    None => [ for _ in 0..<stripe.rows => true ]
  }
  (present, get_stream(file, ss, column, 1).unwrap_or(b""))
}

///|
fn present_count(present : Array[Bool]) -> Int {
  let mut count = 0
  for p in present {
    if p {
      count += 1
    }
  }
  count
}

///|
/// Read a top-level BOOLEAN column, preserving null values.
pub fn OrcFile::read_bool_column(
  file : OrcFile,
  name : String,
) -> Array[Bool?] raise OrcError {
  let column = primitive_column(file, name, 0)
  let out : Array[Bool?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (present, data) = primitive_stripe(file, stripe, column)
    let values = bits(data, present_count(present))
    let mut pos = 0
    for p in present {
      if p {
        out.push(Some(values[pos]))
        pos += 1
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

///|
fn Cursor::little_endian(c : Cursor, n : Int) -> UInt64 raise OrcError {
  let mut raw = 0UL
  for i in 0..<n {
    raw = raw | (c.byte().to_uint64() << (i * 8))
  }
  raw
}

///|
/// Read a top-level FLOAT column as nullable IEEE-754 single-precision values.
pub fn OrcFile::read_float_column(
  file : OrcFile,
  name : String,
) -> Array[Float?] raise OrcError {
  let column = primitive_column(file, name, 5)
  let out : Array[Float?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (present, data) = primitive_stripe(file, stripe, column)
    if data.length() != present_count(present) * 4 {
      raise Invalid("incorrect FLOAT stream length")
    }
    let c = Cursor::{ data, pos: 0, }
    for p in present {
      if p {
        out.push(
          Some(Float::reinterpret_from_uint(c.little_endian(4).to_uint())),
        )
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

///|
/// Read a top-level DOUBLE column as nullable IEEE-754 double-precision values.
pub fn OrcFile::read_double_column(
  file : OrcFile,
  name : String,
) -> Array[Double?] raise OrcError {
  let column = primitive_column(file, name, 6)
  let out : Array[Double?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (present, data) = primitive_stripe(file, stripe, column)
    if data.length() != present_count(present) * 8 {
      raise Invalid("incorrect DOUBLE stream length")
    }
    let c = Cursor::{ data, pos: 0, }
    for p in present {
      if p {
        out.push(Some(c.little_endian(8).reinterpret_as_double()))
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
