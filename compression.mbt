///|
// ORC compression blocks use a three-byte little-endian header. The least
// significant bit selects an uncompressed block; the remaining bits give
// its on-disk length. ORC's ZLIB codec uses raw DEFLATE, without a zlib wrapper.
fn decompress_stream(
  data : Bytes,
  compression : Int,
  block_size : Int,
) -> Bytes raise OrcError {
  if compression == 0 {
    return data
  }
  if compression != 1 && compression != 2 {
    raise Invalid("unsupported compression codec")
  }
  let c = Cursor::{ data, pos: 0, }
  let output : Array[Byte] = []
  let max_stream = 64 * 1024 * 1024
  while c.pos < data.length() {
    if data.length() - c.pos < 3 {
      raise Invalid("truncated compression header")
    }
    let header = c.byte() | (c.byte() << 8) | (c.byte() << 16)
    let n = header >> 1
    if n == 0 {
      raise Invalid("empty compression block")
    }
    let payload = c.take(n)
    let block = if (header & 1) == 1 {
      if n > block_size {
        raise Invalid("compression block exceeds declared size")
      }
      payload
    } else if compression == 1 {
      @zlib.deflate_decompress(payload, max_size=block_size) catch {
        _ => raise Invalid("invalid or oversized DEFLATE block")
      }
    } else {
      decode_snappy(payload, block_size)
    }
    if block.length() > max_stream - output.length() {
      raise Invalid("decompressed stream exceeds 64 MiB limit")
    }
    for b in block {
      output.push(b)
    }
  }
  Bytes::from_array(output)
}

///|
// Decode a raw Snappy block; bound the announced size before allocating and
// check each literal and copy range, including overlapping copies.
fn decode_snappy(data : Bytes, block_size : Int) -> Bytes raise OrcError {
  let c = Cursor::{ data, pos: 0, }
  let expected = c.varint()
  if block_size < 0 || expected > block_size.to_uint64() {
    raise Invalid("Snappy block exceeds declared size")
  }
  let out : Array[Byte] = []
  while out.length().to_uint64() < expected {
    let tag = c.byte()
    let tag_type = tag & 3
    if tag_type == 0 {
      let prefix = tag >> 2
      let length = if prefix < 60 {
        (prefix + 1).to_uint64()
      } else {
        let mut n = 0UL
        for i in 0..<(prefix - 59) {
          n = n | (c.byte().to_uint64() << (8 * i))
        }
        n + 1UL
      }
      if length > expected - out.length().to_uint64() ||
        length > (data.length() - c.pos).to_uint64() {
        raise Invalid("invalid Snappy literal length")
      }
      for _ in 0..<length.to_int() {
        out.push(c.data[c.pos])
        c.pos += 1
      }
    } else {
      let (length, offset) = if tag_type == 1 {
        (((tag >> 2) & 7) + 4, ((tag >> 5 << 8) | c.byte()).to_uint64())
      } else if tag_type == 2 {
        ((tag >> 2) + 1, (c.byte() | (c.byte() << 8)).to_uint64())
      } else {
        let mut offset = 0UL
        for i in 0..<4 {
          offset = offset | (c.byte().to_uint64() << (8 * i))
        }
        ((tag >> 2) + 1, offset)
      }
      if offset == 0UL ||
        offset > out.length().to_uint64() ||
        length.to_uint64() > expected - out.length().to_uint64() {
        raise Invalid("invalid Snappy copy")
      }
      let distance = offset.to_int()
      for _ in 0..<length {
        out.push(out[out.length() - distance])
      }
    }
  }
  if c.pos != data.length() {
    raise Invalid("trailing data in Snappy block")
  }
  Bytes::from_array(out)
}
