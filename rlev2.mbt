///|
priv struct BitReader {
  cursor : Cursor
  mut byte : Int
  mut left : Int
}

///|
fn BitReader::read(r : BitReader, width : Int) -> UInt64 raise OrcError {
  let mut value = 0UL
  for _ in 0..<width {
    if r.left == 0 {
      r.byte = r.cursor.byte()
      r.left = 8
    }
    r.left -= 1
    value = (value << 1) | ((r.byte >> r.left) & 1).to_uint64()
  }
  value
}

///|
fn rle_width(code : Int) -> Int {
  if code < 24 {
    code + 1
  } else {
    [26, 28, 30, 32, 40, 48, 56, 64][code - 24]
  }
}

///|
fn rounded_width(width : Int) -> Int raise OrcError {
  if width > 64 {
    raise Invalid("patch width exceeds 64 bits")
  }
  for code in 0..<32 {
    let w = rle_width(code)
    if w >= width {
      return w
    }
  }
  raise Invalid("invalid patch width")
}

///|
// Transform the signed ordering to unsigned ordering to check additions
// even when a positive delta or a base-relative value is larger than Int64.MAX.
fn add_unsigned(
  base : Int64,
  delta : UInt64,
  negative : Bool,
) -> Int64 raise OrcError {
  let ordered = base.reinterpret_as_uint64() ^ 9223372036854775808UL
  let next = if negative {
    if delta > ordered {
      raise Invalid("RLEv2 integer overflow")
    }
    ordered - delta
  } else {
    if delta > 18446744073709551615UL - ordered {
      raise Invalid("RLEv2 integer overflow")
    }
    ordered + delta
  }
  (next ^ 9223372036854775808UL).reinterpret_as_int64()
}

///|
fn add_signed(base : Int64, delta : Int64) -> Int64 raise OrcError {
  let negative = delta < 0L
  let magnitude = if negative {
    (-(delta + 1L)).reinterpret_as_uint64() + 1UL
  } else {
    delta.reinterpret_as_uint64()
  }
  add_unsigned(base, magnitude, negative)
}

///|
fn int_rle_v2(data : Bytes, count : Int) -> Array[Int64] raise OrcError {
  let c = Cursor::{ data, pos: 0, }
  let out : Array[Int64] = []
  while c.pos < data.length() {
    let h = c.byte()
    let kind = h >> 6
    if kind == 0 {
      let width = ((h >> 3) & 7) + 1
      let len = (h & 7) + 3
      if len > count - out.length() {
        raise Invalid("RLEv2 exceeds expected size")
      }
      let mut raw = 0UL
      for _ in 0..<width {
        raw = (raw << 8) | c.byte().to_uint64()
      }
      let value = zigzag(raw)
      for _ in 0..<len {
        out.push(value)
      }
      continue
    }
    let encoded_width = (h >> 1) & 31
    let len = (((h & 1) << 8) | c.byte()) + 1
    if len > count - out.length() {
      raise Invalid("RLEv2 exceeds expected size")
    }
    if kind == 1 {
      let bits = BitReader::{ cursor: c, byte: 0, left: 0, }
      let width = rle_width(encoded_width)
      for _ in 0..<len {
        out.push(zigzag(bits.read(width)))
      }
    } else if kind == 3 {
      let width = if encoded_width == 0 { 0 } else { rle_width(encoded_width) }
      let base = zigzag(c.varint())
      let delta = zigzag(c.varint())
      out.push(base)
      if len > 1 {
        let mut previous = add_signed(base, delta)
        out.push(previous)
        if width == 0 {
          for _ in 2..<len {
            previous = add_signed(previous, delta)
            out.push(previous)
          }
        } else {
          if delta == 0L {
            raise Invalid("variable delta has zero direction")
          }
          let bits = BitReader::{ cursor: c, byte: 0, left: 0, }
          for _ in 2..<len {
            previous = add_unsigned(previous, bits.read(width), delta < 0L)
            out.push(previous)
          }
        }
      }
    } else {
      let width = rle_width(encoded_width)
      let third = c.byte()
      let fourth = c.byte()
      let base_width = (third >> 5) + 1
      let patch_width = rle_width(third & 31)
      let gap_width = (fourth >> 5) + 1
      let patch_len = fourth & 31
      if patch_len == 0 ||
        width + patch_width > 64 ||
        gap_width + patch_width > 64 {
        raise Invalid("invalid RLEv2 patch widths or count")
      }
      let mut raw_base = 0UL
      for _ in 0..<base_width {
        raw_base = (raw_base << 8) | c.byte().to_uint64()
      }
      let sign = 1UL << (base_width * 8 - 1)
      let magnitude = (raw_base & (sign - 1UL)).reinterpret_as_int64()
      let base = if (raw_base & sign) != 0UL { -magnitude } else { magnitude }
      let bits = BitReader::{ cursor: c, byte: 0, left: 0, }
      let values : Array[UInt64] = [ for _ in 0..<len => bits.read(width) ]
      let patch_bits = BitReader::{ cursor: c, byte: 0, left: 0, }
      let total_width = rounded_width(gap_width + patch_width)
      let patch_mask = (1UL << patch_width) - 1UL
      let mut index = 0
      let mut extension = 0
      let mut first = true
      for _ in 0..<patch_len {
        let patch_entry = patch_bits.read(total_width)
        let gap = (patch_entry >> patch_width).to_int()
        let patch = patch_entry & patch_mask
        if gap >= 1 << gap_width {
          raise Invalid("invalid RLEv2 patch gap")
        }
        if gap == 255 && patch == 0UL {
          extension += 255
          if extension > len {
            raise Invalid("RLEv2 patch outside run")
          }
          continue
        }
        if patch == 0UL {
          raise Invalid("invalid empty RLEv2 patch")
        }
        let step = extension + gap
        if !first && step == 0 {
          raise Invalid("duplicate RLEv2 patch")
        }
        index += step
        if index >= len {
          raise Invalid("RLEv2 patch outside run")
        }
        values[index] = values[index] | (patch << width)
        extension = 0
        first = false
      }
      if extension != 0 {
        raise Invalid("incomplete RLEv2 patch gap")
      }
      for value in values {
        out.push(add_unsigned(base, value, false))
      }
    }
  }
  if out.length() != count {
    raise Invalid("incorrect RLEv2 stream length")
  }
  out
}
