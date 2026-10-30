///|
/// Read a top-level LIST<BINARY>, preserving null lists and null elements.
/// Empty byte strings and empty lists remain distinct. At most ten million
/// elements are decoded across the file.
pub fn OrcFile::read_binary_list_column(
  file : OrcFile,
  name : String,
) -> Array[Array[Bytes?]?] raise OrcError {
  let column = primitive_column(file, name, 10)
  let children = file.types[column].children
  if children.length() != 1 {
    raise Invalid("invalid list element schema")
  }
  let child = children[0]
  if child <= column || child >= file.types.length() {
    raise Invalid("invalid list element column")
  }
  if file.types[child].kind != 8 {
    raise Invalid("list elements must be BINARY")
  }
  let out : Array[Array[Bytes?]?] = []
  let mut total_elements = 0
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() || child >= encodings.length() {
      raise Invalid("missing list column encoding")
    }
    let child_encoding = encodings[child].kind
    if child_encoding != 0 && child_encoding != 2 {
      raise Invalid("unsupported binary encoding")
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
    let data = get_stream(file, ss, child, 1).unwrap_or(b"")
    let value_lengths = get_stream(file, ss, child, 2).unwrap_or(b"")
    let values = binary_values(
      data,
      unsigned_rle(
        value_lengths,
        present_count(element_present),
        child_encoding == 2,
      ),
    )
    let mut length_index = 0
    let mut element_index = 0
    let mut value_index = 0
    for p in present {
      if p {
        let row : Array[Bytes?] = []
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
