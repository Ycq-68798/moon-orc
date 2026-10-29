///|
/// An exact decimal value: `unscaled * 10^(-scale)`.
pub(all) struct OrcDecimal {
  unscaled : Int64
  scale : Int
}

///|
/// Read a top-level DECIMAL column with precision 1..18. Values retain the
/// declared scale; differing per-value scales and out-of-precision values are
/// rejected rather than rounded or truncated.
pub fn OrcFile::read_decimal_column(
  file : OrcFile,
  name : String,
) -> Array[OrcDecimal?] raise OrcError {
  let column = primitive_column(file, name, 14)
  let precision = file.decimal_precision[column]
  let scale = file.decimal_scale[column]
  if precision < 1 || precision > 18 || scale < 0 || scale > precision {
    raise Invalid("unsupported decimal precision or scale")
  }
  let mut limit = 1L
  for _ in 0..<precision {
    limit *= 10L
  }
  let out : Array[OrcDecimal?] = []
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
      raise Invalid("unsupported decimal encoding")
    }
    let present = match get_stream(file, ss, column, 0) {
      Some(data) => bits(data, stripe.rows)
      None => [ for _ in 0..<stripe.rows => true ]
    }
    let count = present_count(present)
    let data = get_stream(file, ss, column, 1).unwrap_or(b"")
    let scales_data = get_stream(file, ss, column, 5).unwrap_or(b"")
    let scales = if encoding == 0 {
      int_rle(scales_data, count)
    } else {
      int_rle_v2(scales_data, count)
    }
    let cursor = Cursor::{ data, pos: 0, }
    let mut index = 0
    for p in present {
      if p {
        let unscaled = zigzag(cursor.varint())
        if unscaled <= -limit || unscaled >= limit {
          raise Invalid("decimal value exceeds declared precision")
        }
        if scales[index] != Int64::from_int(scale) {
          raise Invalid("decimal value scale differs from declared scale")
        }
        out.push(Some({ unscaled, scale, }))
        index += 1
      } else {
        out.push(None)
      }
    }
    if cursor.pos != data.length() {
      raise Invalid("trailing bytes in decimal data stream")
    }
  }
  if out.length() != file.rows {
    raise Invalid("stripe row count does not match footer")
  }
  out
}
