///|
test "PyArrow nullable string lists" {
  for
    bytes in [
      fixture_string_list_v011_uncompressed_direct(),
      fixture_string_list_v011_uncompressed_dict(),
      fixture_string_list_v011_zlib_direct(),
      fixture_string_list_v011_zlib_dict(),
      fixture_string_list_v011_snappy_direct(),
      fixture_string_list_v011_snappy_dict(),
      fixture_string_list_v012_uncompressed_direct(),
      fixture_string_list_v012_uncompressed_dict(),
      fixture_string_list_v012_zlib_direct(),
      fixture_string_list_v012_zlib_dict(),
      fixture_string_list_v012_snappy_direct(),
      fixture_string_list_v012_snappy_dict(),
    ] {
    let file = open(bytes)
    let rows = file.read_string_list_column("text")
    assert_eq(rows.length(), 240)
    for i in 0..<240 {
      match i % 6 {
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
                Some(""),
                None,
                Some("中文"),
                Some("🍉"),
                Some("\u{feff}"),
                Some("x "),
              ])
            None => fail("expected list")
          }
        3 =>
          match rows[i] {
            Some(row) => assert_eq(row, [Some("重复"), Some("重复"), None])
            None => fail("expected list")
          }
        4 =>
          match rows[i] {
            Some(row) => assert_eq(row, [None, None])
            None => fail("expected list")
          }
        _ =>
          match rows[i] {
            Some(row) => assert_eq(row, [Some(""), Some("MoonBit")])
            None => fail("expected list")
          }
      }
    }
    assert_true(file.read_string_list_column("all_null")[0] is None)
    let missing = try file.read_string_list_column("missing") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(missing)
  }
  let integers = open(fixture_list_v012_uncompressed())
  let wrong = try integers.read_string_list_column("tiny") catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(wrong)
}

///|
test "PyArrow multi-stripe string lists" {
  for
    bytes in [
      fixture_string_list_multi_v011_uncompressed_direct(),
      fixture_string_list_multi_v011_uncompressed_dict(),
      fixture_string_list_multi_v012_uncompressed_direct(),
      fixture_string_list_multi_v012_uncompressed_dict(),
      fixture_string_list_multi_v012_zlib_direct(),
      fixture_string_list_multi_v012_zlib_dict(),
      fixture_string_list_multi_v012_snappy_direct(),
      fixture_string_list_multi_v012_snappy_dict(),
    ] {
    let file = open(bytes)
    assert_true(file.stripes.length() > 1)
    let rows = file.read_string_list_column("text")
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
              assert_eq(row, [None, Some(""), Some("中文"), Some("🍉")])
            None => fail("expected list")
          }
        _ =>
          match rows[i] {
            Some(row) =>
              assert_eq(row, [Some("MoonBit"), Some("MoonBit"), Some("x ")])
            None => fail("expected list")
          }
      }
    }
  }
}

///|
test "reject malformed string list streams" {
  for
    bytes in [
      fixture_bad_string_list_parent_present(),
      fixture_bad_string_list_parent_length(),
      fixture_bad_string_list_child_present(),
      fixture_bad_string_list_child_data(),
      fixture_bad_string_list_child_length(),
      fixture_bad_string_list_dict_ids(),
      fixture_bad_string_list_dict_data(),
      fixture_bad_string_list_invalid_utf8(),
      fixture_bad_string_list_dict_invalid_utf8(),
      fixture_bad_string_list_dict_index(),
      fixture_bad_string_list_too_many(),
    ] {
    let rejected = try open(bytes).read_string_list_column("text") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
  try
    open(fixture_bad_string_list_dict_index()).read_string_list_column("text")
  catch {
    Invalid(message) => assert_eq(message, "invalid dictionary index")
  } noraise {
    _ => fail("expected invalid dictionary index")
  }
  for
    bytes in [
      fixture_bad_string_list_invalid_utf8(),
      fixture_bad_string_list_dict_invalid_utf8(),
    ] {
    try open(bytes).read_string_list_column("text") catch {
      Invalid(message) => assert_eq(message, "invalid UTF-8 in string column")
    } noraise {
      _ => fail("expected invalid UTF-8")
    }
  }
  try
    open(fixture_bad_string_list_too_many()).read_string_list_column("text")
  catch {
    Invalid(message) =>
      assert_eq(message, "list exceeds ten million element limit")
  } noraise {
    _ => fail("expected list element limit")
  }
}
