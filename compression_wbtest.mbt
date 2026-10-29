///|
test "ZLIB original and compressed chunks concatenate" {
  let compressed = @zlib.deflate_compress(b"hello hello hello")
  let length = compressed.length() * 2
  let data : Array[Byte] = [0x07, 0x00, 0x00, b'a', b'b', b'c']
  data.push((length & 255).to_byte())
  data.push(((length >> 8) & 255).to_byte())
  data.push(((length >> 16) & 255).to_byte())
  for b in compressed {
    data.push(b)
  }
  assert_eq(
    decompress_stream(Bytes::from_array(data), 1, 100),
    b"abchello hello hello",
  )
}

///|
test "ZLIB rejects malformed chunks and excessive expansion" {
  let truncated_header = try decompress_stream([0x01], 1, 10) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let truncated_data = try
    decompress_stream([0x07, 0x00, 0x00, 0x01], 1, 10)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let oversized_original = try
    decompress_stream([0x07, 0x00, 0x00, 0x01, 0x02, 0x03], 1, 2)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let invalid_deflate = try
    decompress_stream([0x02, 0x00, 0x00, 0xff], 1, 10)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let empty = try decompress_stream([0x00, 0x00, 0x00], 1, 10) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let compressed = @zlib.deflate_compress(b"hello hello hello")
  let header = compressed.length() * 2
  let encoded = [
    (header & 255).to_byte(),
    ((header >> 8) & 255).to_byte(),
    ((header >> 16) & 255).to_byte(),
  ]
  for b in compressed {
    encoded.push(b)
  }
  let oversized_inflate = try
    decompress_stream(Bytes::from_array(encoded), 1, 2)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(
    truncated_header &&
    truncated_data &&
    oversized_original &&
    invalid_deflate &&
    empty &&
    oversized_inflate,
  )
}

///|
test "Arrow writes multiple ZLIB chunks in one data stream" {
  let file = open(fixture_zlib_multi())
  let (ss, _) = streams(file, file.stripes[0])
  let mut found = false
  for s in ss {
    if s.column == 1 && s.kind == 1 {
      let raw = file.bytes[s.offset:s.offset + s.length].to_owned()
      let c = Cursor::{ data: raw, pos: 0, }
      let mut chunks = 0
      while c.pos < raw.length() {
        let header = c.byte() | (c.byte() << 8) | (c.byte() << 16)
        let _ = c.take(header >> 1)
        chunks += 1
      }
      found = chunks > 1
    }
  }
  assert_true(found)
}
