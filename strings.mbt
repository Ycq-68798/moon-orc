///|
fn unsigned_rle(
  data : Bytes,
  count : Int,
  v2 : Bool,
) -> Array[Int64] raise OrcError {
  if v2 {
    int_rle_v2(data, count, signed=false)
  } else {
    int_rle(data, count, signed=false)
  }
}

///|
fn decode_string_values(
  data : Bytes,
  lengths : Array[Int64],
) -> Array[String] raise OrcError {
  let out = []
  let mut offset = 0
  for length in lengths {
    if length < 0L || length > Int64::from_int(data.length() - offset) {
      raise Invalid("string length exceeds data stream")
    }
    let end = offset + length.to_int()
    let value = @utf8.decode(data[offset:end]) catch {
      _ => raise Invalid("invalid UTF-8 in string column")
    }
    out.push(value)
    offset = end
  }
  if offset != data.length() {
    raise Invalid("trailing bytes in string data stream")
  }
  out
}

///|
fn dictionary_values(
  dict : Array[String],
  ids : Array[Int64],
) -> Array[String] raise OrcError {
  let selected = []
  for id in ids {
    if id < 0L || id >= Int64::from_int(dict.length()) {
      raise Invalid("invalid dictionary index")
    }
    selected.push(dict[id.to_int()])
  }
  selected
}

///|
fn string_stripe_values(
  file : OrcFile,
  ss : Array[Stream],
  column : Int,
  encoding : ColumnEncoding,
  count : Int,
) -> Array[String] raise OrcError {
  if encoding.kind < 0 || encoding.kind > 3 {
    raise Invalid("unsupported string encoding")
  }
  let v2 = encoding.kind == 2 || encoding.kind == 3
  let dictionary = encoding.kind == 1 || encoding.kind == 3
  let lengths_data = get_stream(file, ss, column, 2).unwrap_or(b"")
  let value_data = get_stream(file, ss, column, 1).unwrap_or(b"")
  if dictionary {
    if encoding.dictionary_size > 10000000 {
      raise Invalid("dictionary exceeds 10 million entry limit")
    }
    let dictionary_data = get_stream(file, ss, column, 3).unwrap_or(b"")
    let lengths = unsigned_rle(lengths_data, encoding.dictionary_size, v2)
    let dict = decode_string_values(dictionary_data, lengths)
    let ids = unsigned_rle(value_data, count, v2)
    dictionary_values(dict, ids)
  } else {
    let lengths = unsigned_rle(lengths_data, count, v2)
    decode_string_values(value_data, lengths)
  }
}

///|
/// Read a top-level STRING, VARCHAR or CHAR column, preserving nulls and
/// the UTF-8 text stored by the writer, including trailing spaces.
pub fn OrcFile::read_string_column(
  file : OrcFile,
  name : String,
) -> Array[String?] raise OrcError {
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
  if kind != 7 && kind != 16 && kind != 17 {
    raise Invalid("column is not a string type")
  }
  let output : Array[String?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - output.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() {
      raise Invalid("missing column encoding")
    }
    let encoding = encodings[column]
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
    let values = string_stripe_values(file, ss, column, encoding, count)
    let mut pos = 0
    for p in present {
      if p {
        output.push(Some(values[pos]))
        pos += 1
      } else {
        output.push(None)
      }
    }
  }
  if output.length() != file.rows {
    raise Invalid("stripe row count does not match footer")
  }
  output
}
