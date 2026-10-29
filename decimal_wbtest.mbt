///|
test "PyArrow decimal formats and compression" {
  for
    bytes in [
      fixture_decimal_v011_uncompressed(),
      fixture_decimal_v011_zlib(),
      fixture_decimal_v011_snappy(),
      fixture_decimal_v012_uncompressed(),
      fixture_decimal_v012_zlib(),
      fixture_decimal_v012_snappy(),
    ] {
    let file = open(bytes)
    let values = file.read_decimal_column("amount")
    let expected : Array[Int64] = [
      -999999999999999999L, -10001L, 0L, 1L, 999999999999999999L,
    ]
    for i in 0..<5 {
      match values[i] {
        Some(d) => {
          assert_eq(d.unscaled, expected[i])
          assert_eq(d.scale, 4)
        }
        None => fail("expected decimal")
      }
    }
    assert_true(values[5] is None)
    assert_true(file.read_decimal_column("all_null")[0] is None)
    let small = file.read_decimal_column("small")
    let frac = file.read_decimal_column("frac")
    match small[0] {
      Some(d) => {
        assert_eq(d.unscaled, -9L)
        assert_eq(d.scale, 0)
      }
      None => fail("expected decimal")
    }
    match frac[0] {
      Some(d) => {
        assert_eq(d.unscaled, -999999999999999999L)
        assert_eq(d.scale, 18)
      }
      None => fail("expected decimal")
    }
    let wide = try file.read_decimal_column("wide") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(wide)
  }
}

///|
test "PyArrow multi-stripe decimals" {
  for
    bytes in [
      fixture_decimal_multi_uncompressed(),
      fixture_decimal_multi_zlib(),
      fixture_decimal_multi_snappy(),
    ] {
    let file = open(bytes)
    assert_true(file.stripes.length() > 1)
    let values = file.read_decimal_column("amount")
    for i in 0..<2000 {
      if i % 7 == 0 {
        assert_true(values[i] is None)
      } else {
        match values[i] {
          Some(d) => {
            assert_eq(d.unscaled, Int64::from_int(i - 1000))
            assert_eq(d.scale, 4)
          }
          None => fail("expected decimal")
        }
      }
    }
  }
}

///|
test "reject truncated decimal streams and invalid types" {
  for
    bytes in [
      fixture_bad_decimal_data(),
      fixture_bad_decimal_scale(),
      fixture_bad_decimal_present(),
      fixture_bad_decimal_precision(),
      fixture_bad_decimal_scale_mismatch(),
      fixture_bad_decimal_bad_schema(),
      fixture_bad_decimal_overflow(),
      fixture_bad_decimal_trailing(),
    ] {
    let rejected = try open(bytes).read_decimal_column("amount") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
  let file = open(fixture_decimal_v012_uncompressed())
  let missing = try file.read_decimal_column("missing") catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let wrong = try file.read_int_column("amount") catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(missing && wrong)
}
