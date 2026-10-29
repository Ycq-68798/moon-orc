///|
test "RLEv2 official specification vectors" {
  // Signed versions of the specification's short repeat, direct and delta
  // examples use zigzag-adjusted values; patched base is sign-magnitude.
  assert_eq(int_rle_v2([0x0a, 0x4e, 0x20], 5), [
    10000L, 10000L, 10000L, 10000L, 10000L,
  ])
  assert_eq(
    int_rle_v2([0x5e, 0x03, 0x5c, 0xa1, 0xab, 0x1e, 0xde, 0xad, 0xbe, 0xef], 4),
    [-11857L, 21903L, -28503L, -24440L],
  )
  assert_eq(int_rle_v2([0xc6, 0x09, 0x04, 0x02, 0x22, 0x42, 0x42, 0x46], 10), [
    2L, 3L, 5L, 7L, 11L, 13L, 17L, 19L, 23L, 29L,
  ])
  assert_eq(
    int_rle_v2(
      [
        0x8e, 0x13, 0x2b, 0x21, 0x07, 0xd0, 0x1e, 0x00, 0x14, 0x70, 0x28, 0x32, 0x3c,
        0x46, 0x50, 0x5a, 0x64, 0x6e, 0x78, 0x82, 0x8c, 0x96, 0xa0, 0xaa, 0xb4, 0xbe,
        0xfc, 0xe8,
      ],
      20,
    ),
    [
      2030L, 2000L, 2020L, 1000000L, 2040L, 2050L, 2060L, 2070L, 2080L, 2090L, 2100L,
      2110L, 2120L, 2130L, 2140L, 2150L, 2160L, 2170L, 2180L, 2190L,
    ],
  )
}

///|
test "RLEv2 rejects truncated, overflow and invalid patch streams" {
  let vectors : Array[(Bytes, Int)] = [
    ([0x0a, 0x4e, 0x20], 5),
    ([0x5e, 0x03, 0x5c, 0xa1, 0xab, 0x1e, 0xde, 0xad, 0xbe, 0xef], 4),
    ([0xc6, 0x09, 0x04, 0x02, 0x22, 0x42, 0x42, 0x46], 10),
    (
      [
        0x8e, 0x13, 0x2b, 0x21, 0x07, 0xd0, 0x1e, 0x00, 0x14, 0x70, 0x28, 0x32, 0x3c,
        0x46, 0x50, 0x5a, 0x64, 0x6e, 0x78, 0x82, 0x8c, 0x96, 0xa0, 0xaa, 0xb4, 0xbe,
        0xfc, 0xe8,
      ],
      20,
    ),
  ]
  for (data, count) in vectors {
    for end in 0..<data.length() {
      let rejected = try int_rle_v2(data[:end].to_owned(), count) catch {
        Invalid(_) => true
      } noraise {
        _ => false
      }
      assert_true(rejected)
    }
  }
  let over_count = try int_rle_v2([0x0a, 0x4e, 0x20], 4) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let overflow = try
    int_rle_v2(
      [
        0xc0, 0x01, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x02,
      ],
      2,
    )
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let empty_patches = try int_rle_v2([0x80, 0x00, 0x00, 0x00], 1) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let out_of_range = try
    int_rle_v2([0x80, 0x00, 0x00, 0x01, 0x00, 0x00, 0xc0], 1)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let duplicate = try
    int_rle_v2([0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x50], 2)
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(
    over_count && overflow && empty_patches && out_of_range && duplicate,
  )
}

///|
test "RLEv2 arithmetic covers full signed domain" {
  assert_eq(
    add_unsigned(-9223372036854775808L, 18446744073709551615UL, false),
    9223372036854775807L,
  )
  assert_eq(
    add_unsigned(9223372036854775807L, 18446744073709551615UL, true),
    -9223372036854775808L,
  )
  assert_eq(add_signed(0L, -9223372036854775808L), -9223372036854775808L)
}

///|
test "RLEv2 delta supports a 64-bit unsigned step" {
  let data : Bytes = [
    0xfe, 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x02,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
  ]
  assert_eq(int_rle_v2(data, 3), [
    -9223372036854775808L, -9223372036854775807L, 9223372036854775807L,
  ])
}
