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
  if compression != 1 {
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
    } else {
      @zlib.deflate_decompress(payload, max_size=block_size) catch {
        _ => raise Invalid("invalid or oversized DEFLATE block")
      }
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
