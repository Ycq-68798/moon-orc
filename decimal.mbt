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

///|
/// An exact decimal whose signed unscaled coefficient is a base-10 integer.
/// Its value is `unscaled * 10^(-scale)`.
pub(all) struct OrcDecimal128 {
  unscaled : String
  scale : Int
}

///|
fn decimal128_varint(cursor : Cursor, precision : Int) -> String raise OrcError {
  let chunks : Array[Int] = []
  let mut complete = false
  for i in 0..<19 {
    let b = cursor.byte()
    if i == 18 && b > 3 {
      raise Invalid("decimal varint exceeds 128 bits")
    }
    chunks.push(b & 127)
    if b < 128 {
      complete = true
      break
    }
  }
  if !complete {
    raise Invalid("decimal varint exceeds 128 bits")
  }
  // Convert the unsigned zigzag integer to base-10 digits, least significant first.
  let digits : Array[Int] = [0]
  for i = chunks.length() - 1; i >= 0; i = i - 1 {
    let mut carry = chunks[i]
    for j in 0..<digits.length() {
      let n = digits[j] * 128 + carry
      digits[j] = n % 10
      carry = n / 10
    }
    while carry > 0 {
      digits.push(carry % 10)
      carry = carry / 10
    }
  }
  let negative = digits[0] % 2 == 1
  let mut carry = 0
  for i = digits.length() - 1; i >= 0; i = i - 1 {
    let n = carry * 10 + digits[i]
    digits[i] = n / 2
    carry = n % 2
  }
  if negative {
    let mut index = 0
    let mut increment = 1
    while increment > 0 && index < digits.length() {
      let n = digits[index] + increment
      digits[index] = n % 10
      increment = n / 10
      index += 1
    }
    if increment > 0 {
      digits.push(increment)
    }
  }
  while digits.length() > 1 && digits[digits.length() - 1] == 0 {
    let _ = digits.pop()
  }
  if digits.length() > precision {
    raise Invalid("decimal value exceeds declared precision")
  }
  let mut result = if negative { "-" } else { "" }
  for i = digits.length() - 1; i >= 0; i = i - 1 {
    result += digits[i].to_string()
  }
  result
}

///|
/// Read a top-level DECIMAL of precision 1..38 without precision loss.
/// A value's scale must match the declared schema scale; no rescaling occurs.
pub fn OrcFile::read_decimal128_column(
  file : OrcFile,
  name : String,
) -> Array[OrcDecimal128?] raise OrcError {
  let column = primitive_column(file, name, 14)
  let precision = file.decimal_precision[column]
  let scale = file.decimal_scale[column]
  if precision < 1 || precision > 38 || scale < 0 || scale > precision {
    raise Invalid("unsupported decimal precision or scale")
  }
  let out : Array[OrcDecimal128?] = []
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
        let unscaled = decimal128_varint(cursor, precision)
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
