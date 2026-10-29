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

///|
test "Snappy raw blocks handle literal and all copy token forms" {
  let copy1 : Bytes = [5, 0, b'a', 1, 1]
  let copy2 : Bytes = [5, 0, b'a', 14, 1, 0]
  let copy4 : Bytes = [5, 0, b'a', 15, 1, 0, 0, 0]
  for block in [copy1, copy2, copy4] {
    validate_snappy(block, 5)
    assert_eq(@snappy.decompress(block), b"aaaaa")
  }
}

///|
test "Snappy rejects malformed and oversized blocks" {
  let cases : Array[Bytes] = [
    [],
    [0x80],
    [5, 0x10, b'a'], // truncated five-byte literal
    [1, 1, 0], // copy offset zero
    [1, 1, 1], // copy before first output byte
    [1, 0xfc, 0xff, 0xff, 0xff, 0xff], // oversized 4-byte literal length
    [1, 0, b'a', 0], // trailing data
    [0x80, 0x80, 0x80, 0x01], // advertised output larger than limit
  ]
  for block in cases {
    let rejected = try validate_snappy(block, 10) catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
}

///|
test "Arrow Snappy data contains multiple compressed blocks" {
  let file = open(fixture_snappy_v12_large())
  let (ss, _) = streams(file, file.stripes[0])
  let mut found = false
  for stream in ss {
    if stream.column == 1 && stream.kind == 1 {
      let raw = file.bytes[stream.offset:stream.offset + stream.length].to_owned()
      let c = Cursor::{ data: raw, pos: 0, }
      let mut compressed = 0
      while c.pos < raw.length() {
        let header = c.byte() | (c.byte() << 8) | (c.byte() << 16)
        let _ = c.take(header >> 1)
        if (header & 1) == 0 {
          compressed += 1
        }
      }
      found = compressed > 1
    }
  }
  assert_true(found)
}

///|
test "Snappy ORC framing validates block payload" {
  assert_eq(decompress_stream([7, 0, 0, b'a', b'b', b'c'], 2, 10), b"abc")
  assert_eq(decompress_stream([10, 0, 0, 5, 0, b'a', 1, 1], 2, 10), b"aaaaa")
  let truncated = try decompress_stream([4, 0, 0, 1, 1], 2, 10) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let too_large = try decompress_stream([2, 0, 0, 0x0b], 2, 10) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(truncated && too_large)
}
