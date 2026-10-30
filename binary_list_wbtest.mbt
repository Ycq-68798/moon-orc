///|
test "PyArrow nullable binary lists" {
  for
    bytes in [
      fixture_binary_list_v011_uncompressed(),
      fixture_binary_list_v011_zlib(),
      fixture_binary_list_v011_snappy(),
      fixture_binary_list_v012_uncompressed(),
      fixture_binary_list_v012_zlib(),
      fixture_binary_list_v012_snappy(),
    ] {
    let file = open(bytes)
    let rows = file.read_binary_list_column("data")
    assert_eq(rows.length(), 6)
    assert_true(rows[0] is None)
    match rows[1] {
      Some(row) => assert_eq(row, [])
      None => fail("expected empty list")
    }
    match rows[2] {
      Some(row) => {
        assert_eq(row.length(), 4)
        assert_eq(row[0], Some(b""))
        assert_true(row[1] is None)
        assert_eq(row[2], Some([0x00, 0xff]))
        match row[3] {
          Some(value) => {
            assert_eq(value.length(), 256)
            for i in 0..<256 {
              assert_eq(value[i].to_int(), i)
            }
          }
          None => fail("expected binary value")
        }
      }
      None => fail("expected list")
    }
    assert_eq(rows[3], Some([None]))
    assert_eq(rows[4], Some([Some(b"abc")]))
    assert_eq(rows[5], Some([None, None]))
    assert_eq(file.read_binary_list_column("all_null"), [
      None,
      None,
      None,
      None,
      None,
      None,
    ])
    let missing = try file.read_binary_list_column("missing") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    let wrong = try
      open(fixture_list_v012_uncompressed()).read_binary_list_column("tiny")
    catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(missing && wrong)
  }
}

///|
test "PyArrow multi-stripe binary lists" {
  for
    bytes in [
      fixture_binary_list_multi_v011_uncompressed(),
      fixture_binary_list_multi_v012_uncompressed(),
      fixture_binary_list_multi_v012_zlib(),
      fixture_binary_list_multi_v012_snappy(),
    ] {
    let file = open(bytes)
    assert_true(file.stripes.length() > 1)
    let rows = file.read_binary_list_column("data")
    assert_eq(rows.length(), 2000)
    for i in 0..<2000 {
      match i % 4 {
        0 => assert_true(rows[i] is None)
        1 => assert_eq(rows[i], Some([]))
        2 => assert_eq(rows[i], Some([None, Some(b""), Some([0x00, 0xff])]))
        _ => assert_eq(rows[i], Some([Some(b"abc"), None]))
      }
    }
  }
}

///|
test "reject malformed binary list streams" {
  for
    bytes in [
      fixture_bad_binary_list_parent_present(),
      fixture_bad_binary_list_parent_length(),
      fixture_bad_binary_list_child_present(),
      fixture_bad_binary_list_child_data(),
      fixture_bad_binary_list_child_length(),
      fixture_bad_binary_list_too_many(),
    ] {
    let rejected = try open(bytes).read_binary_list_column("data") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
  try
    open(fixture_bad_binary_list_too_many()).read_binary_list_column("data")
  catch {
    Invalid(message) =>
      assert_eq(message, "list exceeds ten million element limit")
  } noraise {
    _ => fail("expected list length limit")
  }
}
