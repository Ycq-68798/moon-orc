///|
test "RLEv1 rejects malformed data" {
  let truncated = try int_rle([0xff, 0x80], 1) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let excessive = try byte_rle([0x7f, 0x00], 1) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let overflow = try
    int_rle(
      [0x00, 0x01, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      3,
    )
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(truncated)
  assert_true(excessive)
  assert_true(overflow)
}
