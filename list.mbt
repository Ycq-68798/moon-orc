///|
fn list_layout(
  file : OrcFile,
  ss : Array[Stream],
  stripe : Stripe,
  column : Int,
  child : Int,
  encoding : Int,
  remaining : Int,
) -> (Array[Bool], Array[Int64], Array[Bool]) raise OrcError {
  if encoding != 0 && encoding != 2 {
    raise Invalid("unsupported list encoding")
  }
  let present = match get_stream(file, ss, column, 0) {
    Some(data) => bits(data, stripe.rows)
    None => [ for _ in 0..<stripe.rows => true ]
  }
  let length_data = get_stream(file, ss, column, 2).unwrap_or(b"")
  let lengths = unsigned_rle(length_data, present_count(present), encoding == 2)
  let mut count = 0
  for length in lengths {
    if length > Int64::from_int(remaining - count) {
      raise Invalid("list exceeds ten million element limit")
    }
    count += length.to_int()
  }
  let element_present = match get_stream(file, ss, child, 0) {
    Some(data) => bits(data, count)
    None => [ for _ in 0..<count => true ]
  }
  (present, lengths, element_present)
}

///|
/// Read a top-level LIST of BYTE, SHORT, INT or LONG values. Both null lists
/// and null elements are preserved. At most ten million elements are decoded.
pub fn OrcFile::read_int_list_column(
  file : OrcFile,
  name : String,
) -> Array[Array[Int64?]?] raise OrcError {
  let column = primitive_column(file, name, 10)
  let children = file.types[column].children
  if children.length() != 1 {
    raise Invalid("invalid list element schema")
  }
  let child = children[0]
  if child <= column || child >= file.types.length() {
    raise Invalid("invalid list element column")
  }
  let kind = file.types[child].kind
  if kind < 1 || kind > 4 {
    raise Invalid("list elements must be integers")
  }
  let out : Array[Array[Int64?]?] = []
  let mut total_elements = 0
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() || child >= encodings.length() {
      raise Invalid("missing list column encoding")
    }
    let list_encoding = encodings[column].kind
    let child_encoding = encodings[child].kind
    if child_encoding != 0 && child_encoding != 2 {
      raise Invalid("unsupported list encoding")
    }
    let (present, lengths, element_present) = list_layout(
      file,
      ss,
      stripe,
      column,
      child,
      list_encoding,
      10000000 - total_elements,
    )
    total_elements += element_present.length()
    let data = get_stream(file, ss, child, 1).unwrap_or(b"")
    let value_count = present_count(element_present)
    let values = if kind == 1 {
      let raw = byte_rle(data, value_count)
      if raw.length() != value_count {
        raise Invalid("incorrect byte stream length")
      }
      [
        for v in raw => Int64::from_int(if v >= 128 { v - 256 } else { v })
      ]
    } else if child_encoding == 0 {
      int_rle(data, value_count)
    } else {
      int_rle_v2(data, value_count)
    }
    let mut length_index = 0
    let mut element_index = 0
    let mut value_index = 0
    for p in present {
      if p {
        let row : Array[Int64?] = []
        for _ in 0..<lengths[length_index].to_int() {
          if element_present[element_index] {
            row.push(Some(values[value_index]))
            value_index += 1
          } else {
            row.push(None)
          }
          element_index += 1
        }
        length_index += 1
        out.push(Some(row))
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
/// Read a top-level LIST<STRING>, preserving null lists and null elements.
/// Empty strings and empty lists remain distinct; text must be valid UTF-8.
/// At most ten million elements are decoded across the file.
pub fn OrcFile::read_string_list_column(
  file : OrcFile,
  name : String,
) -> Array[Array[String?]?] raise OrcError {
  let column = primitive_column(file, name, 10)
  let children = file.types[column].children
  if children.length() != 1 {
    raise Invalid("invalid list element schema")
  }
  let child = children[0]
  if child <= column || child >= file.types.length() {
    raise Invalid("invalid list element column")
  }
  if file.types[child].kind != 7 {
    raise Invalid("list elements must be STRING")
  }
  let out : Array[Array[String?]?] = []
  let mut total_elements = 0
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() || child >= encodings.length() {
      raise Invalid("missing list column encoding")
    }
    let (present, lengths, element_present) = list_layout(
      file,
      ss,
      stripe,
      column,
      child,
      encodings[column].kind,
      10000000 - total_elements,
    )
    total_elements += element_present.length()
    let values = string_stripe_values(
      file,
      ss,
      child,
      encodings[child],
      present_count(element_present),
    )
    let mut length_index = 0
    let mut element_index = 0
    let mut value_index = 0
    for p in present {
      if p {
        let row : Array[String?] = []
        for _ in 0..<lengths[length_index].to_int() {
          if element_present[element_index] {
            row.push(Some(values[value_index]))
            value_index += 1
          } else {
            row.push(None)
          }
          element_index += 1
        }
        length_index += 1
        out.push(Some(row))
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
