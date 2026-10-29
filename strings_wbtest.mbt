///|
test "reject invalid string data and dictionary references" {
  let invalid_utf8 = try decode_string_values([0xff], [1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let excessive_length = try decode_string_values(b"a", [2L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let trailing_data = try decode_string_values(b"ab", [1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let bad_index = try dictionary_values(["hello"], [1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let negative_index = try dictionary_values(["hello"], [-1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let too_large = try
    unsigned_rle(
      [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      1,
      false,
    )
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(
    invalid_utf8 &&
    excessive_length &&
    trailing_data &&
    bad_index &&
    negative_index &&
    too_large,
  )
}

///|
test "unsigned RLEv2 specification vectors for string lengths and indexes" {
  assert_eq(unsigned_rle([0x0a, 0x27, 0x10], 5, true), [
    10000L, 10000L, 10000L, 10000L, 10000L,
  ])
  assert_eq(
    unsigned_rle(
      [0x5e, 0x03, 0x5c, 0xa1, 0xab, 0x1e, 0xde, 0xad, 0xbe, 0xef],
      4,
      true,
    ),
    [23713L, 43806L, 57005L, 48879L],
  )
  assert_eq(
    unsigned_rle([0xc6, 0x09, 0x02, 0x02, 0x22, 0x42, 0x42, 0x46], 10, true),
    [2L, 3L, 5L, 7L, 11L, 13L, 17L, 19L, 23L, 29L],
  )
  assert_eq(
    unsigned_rle(
      [
        0x8e, 0x13, 0x2b, 0x21, 0x07, 0xd0, 0x1e, 0x00, 0x14, 0x70, 0x28, 0x32, 0x3c,
        0x46, 0x50, 0x5a, 0x64, 0x6e, 0x78, 0x82, 0x8c, 0x96, 0xa0, 0xaa, 0xb4, 0xbe,
        0xfc, 0xe8,
      ],
      20,
      true,
    ),
    [
      2030L, 2000L, 2020L, 1000000L, 2040L, 2050L, 2060L, 2070L, 2080L, 2090L, 2100L,
      2110L, 2120L, 2130L, 2140L, 2150L, 2160L, 2170L, 2180L, 2190L,
    ],
  )
}
