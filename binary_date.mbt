///|
fn binary_values(
  data : Bytes,
  lengths : Array[Int64],
) -> Array[Bytes] raise OrcError {
  let values = []
  let mut offset = 0
  for length in lengths {
    if length < 0L || length > Int64::from_int(data.length() - offset) {
      raise Invalid("binary length exceeds data stream")
    }
    let end = offset + length.to_int()
    values.push(data[offset:end].to_owned())
    offset = end
  }
  if offset != data.length() {
    raise Invalid("trailing bytes in binary data stream")
  }
  values
}

///|
/// Read a top-level BINARY column as byte strings; null and empty are distinct.
pub fn OrcFile::read_binary_column(
  file : OrcFile,
  name : String,
) -> Array[Bytes?] raise OrcError {
  let column = primitive_column(file, name, 8)
  let out : Array[Bytes?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() {
      raise Invalid("missing column encoding")
    }
    let encoding = encodings[column].kind
    if encoding != 0 && encoding != 2 {
      raise Invalid("unsupported binary encoding")
    }
    let present = match get_stream(file, ss, column, 0) {
      Some(data) => bits(data, stripe.rows)
      None => [ for _ in 0..<stripe.rows => true ]
    }
    let data = get_stream(file, ss, column, 1).unwrap_or(b"")
    let lengths = get_stream(file, ss, column, 2).unwrap_or(b"")
    let values = binary_values(
      data,
      unsigned_rle(lengths, present_count(present), encoding == 2),
    )
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
/// Read a top-level DATE column as signed days since 1970-01-01 UTC.
/// The result preserves nulls and is restricted to the signed 32-bit range.
pub fn OrcFile::read_date_column(
  file : OrcFile,
  name : String,
) -> Array[Int?] raise OrcError {
  let column = primitive_column(file, name, 15)
  let out : Array[Int?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() {
      raise Invalid("missing column encoding")
    }
    let encoding = encodings[column].kind
    if encoding != 0 && encoding != 2 {
      raise Invalid("unsupported date encoding")
    }
    let present = match get_stream(file, ss, column, 0) {
      Some(data) => bits(data, stripe.rows)
      None => [ for _ in 0..<stripe.rows => true ]
    }
    let data = get_stream(file, ss, column, 1).unwrap_or(b"")
    let values = if encoding == 0 {
      int_rle(data, present_count(present))
    } else {
      int_rle_v2(data, present_count(present))
    }
    let mut pos = 0
    for p in present {
      if p {
        let value = values[pos]
        if value < -2147483648L || value > 2147483647L {
          raise Invalid("date outside signed 32-bit day range")
        }
        out.push(Some(value.to_int()))
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
