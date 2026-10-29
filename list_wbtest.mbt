///|
fn check_integer_list(
  file : OrcFile,
  name : String,
  lo : Int64,
  hi : Int64,
) -> Unit raise {
  let rows = file.read_int_list_column(name)
  assert_eq(rows.length(), 6)
  assert_true(rows[0] is None)
  match rows[1] {
    Some(row) => assert_eq(row, [])
    None => fail("expected empty list")
  }
  match rows[2] {
    Some(row) => assert_eq(row, [None])
    None => fail("expected list")
  }
  match rows[3] {
    Some(row) => assert_eq(row, [Some(0L), Some(-1L), None, Some(1L)])
    None => fail("expected list")
  }
  match rows[4] {
    Some(row) => assert_eq(row, [Some(lo), Some(hi)])
    None => fail("expected list")
  }
  match rows[5] {
    Some(row) => assert_eq(row, [None, None])
    None => fail("expected list")
  }
}

///|
test "PyArrow nullable integer lists" {
  for
    bytes in [
      fixture_list_v011_uncompressed(),
      fixture_list_v011_zlib(),
      fixture_list_v011_snappy(),
      fixture_list_v012_uncompressed(),
      fixture_list_v012_zlib(),
      fixture_list_v012_snappy(),
    ] {
    let file = open(bytes)
    check_integer_list(file, "tiny", -128L, 127L)
    check_integer_list(file, "small", -32768L, 32767L)
    check_integer_list(file, "int", -2147483648L, 2147483647L)
    check_integer_list(file, "big", -9223372036854775808L, 9223372036854775807L)
    assert_true(file.read_int_list_column("all_null")[0] is None)
    let wrong = try file.read_int_list_column("text") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    let missing = try file.read_int_list_column("missing") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(wrong && missing)
  }
}

///|
test "PyArrow multi-stripe integer lists" {
  for
    bytes in [
      fixture_list_multi_uncompressed(),
      fixture_list_multi_zlib(),
      fixture_list_multi_snappy(),
      fixture_list_multi_v011(),
    ] {
    let file = open(bytes)
    assert_true(file.stripes.length() > 1)
    let rows = file.read_int_list_column("numbers")
    for i in 0..<2000 {
      match i % 4 {
        0 => assert_true(rows[i] is None)
        1 =>
          match rows[i] {
            Some(row) => assert_eq(row, [])
            None => fail("expected empty list")
          }
        2 =>
          match rows[i] {
            Some(row) =>
              assert_eq(row, [
                None,
                Some(Int64::from_int(i)),
                Some(Int64::from_int(-i)),
              ])
            None => fail("expected list")
          }
        _ =>
          match rows[i] {
            Some(row) =>
              assert_eq(row, [
                Some(-9223372036854775808L),
                Some(9223372036854775807L),
              ])
            None => fail("expected list")
          }
      }
    }
  }
}

///|
test "reject malformed list streams" {
  for
    bytes in [
      fixture_bad_list_parent_present(),
      fixture_bad_list_length(),
      fixture_bad_list_child_present(),
      fixture_bad_list_child_data(),
      fixture_bad_list_too_many(),
    ] {
    let rejected = try open(bytes).read_int_list_column("tiny") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
  try open(fixture_bad_list_too_many()).read_int_list_column("tiny") catch {
    Invalid(message) =>
      assert_eq(message, "list exceeds ten million element limit")
  } noraise {
    _ => fail("expected list length limit")
  }
}
