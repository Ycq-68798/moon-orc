///|
test "BINARY length and trailing data validation" {
  assert_eq(binary_values([0, 255, 1], [0L, 2L, 1L]), [b"", [0, 255], [1]])
  let too_long = try binary_values([0], [2L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let negative = try binary_values([0], [-1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let trailing = try binary_values([0, 1], [1L]) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(too_long && negative && trailing)
}
