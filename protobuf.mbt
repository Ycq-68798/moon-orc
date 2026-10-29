///|
pub suberror OrcError {
  Invalid(String)
}

///|
priv struct Cursor {
  data : Bytes
  mut pos : Int
}

///|
fn Cursor::byte(c : Cursor) -> Int raise OrcError {
  if c.pos >= c.data.length() {
    raise Invalid("truncated input")
  }
  let v = c.data[c.pos].to_int()
  c.pos += 1
  v
}

///|
fn Cursor::varint(c : Cursor) -> UInt64 raise OrcError {
  let mut value = 0UL
  for i = 0; i < 10; i = i + 1 {
    let b = c.byte()
    if i == 9 && b > 1 {
      raise Invalid("varint overflow")
    }
    value = value | ((b & 127).to_uint64() << (7 * i))
    if b < 128 {
      return value
    }
  }
  raise Invalid("varint overflow")
}

///|
fn checked_int(n : UInt64) -> Int raise OrcError {
  if n > 2147483647UL {
    raise Invalid("length exceeds supported limit")
  }
  n.to_int()
}

///|
fn Cursor::take(c : Cursor, n : Int) -> Bytes raise OrcError {
  if n < 0 || n > c.data.length() - c.pos {
    raise Invalid("truncated input")
  }
  let result = c.data[c.pos:c.pos + n].to_owned()
  c.pos += n
  result
}

///|
priv struct Field {
  number : Int
  wire : Int
  value : UInt64
  bytes : Bytes
}

///|
fn fields(data : Bytes) -> Array[Field] raise OrcError {
  let c = Cursor::{ data, pos: 0, }
  let out = []
  while c.pos < data.length() {
    let tag = checked_int(c.varint())
    let number = tag >> 3
    let wire = tag & 7
    if number == 0 {
      raise Invalid("invalid protobuf tag")
    }
    match wire {
      0 => out.push({ number, wire, value: c.varint(), bytes: b"", })
      1 => {
        let _ = c.take(8)
        out.push({ number, wire, value: 0, bytes: b"", })
      }
      2 => {
        let n = checked_int(c.varint())
        out.push({ number, wire, value: 0, bytes: c.take(n), })
      }
      5 => {
        let _ = c.take(4)
        out.push({ number, wire, value: 0, bytes: b"", })
      }
      _ => raise Invalid("unsupported protobuf wire type")
    }
  }
  out
}

///|
fn number(fs : Array[Field], id : Int, fallback : Int) -> Int raise OrcError {
  for f in fs {
    if f.number == id && f.wire == 0 {
      return checked_int(f.value)
    }
  }
  fallback
}
