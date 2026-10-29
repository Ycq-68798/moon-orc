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
      fixture_bad_decimal_missing_precision(),
      fixture_bad_decimal_missing_scale(),
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

///|
test "PyArrow 38-digit decimals" {
  let magnitude = "99999999999999999999999999999999999999"
  let expected = ["-" + magnitude, "-1", "0", "1", magnitude]
  let varied_expected = [
    "-10000000000000000000000000000000000000", "-987654321098765432109876543210",
    "-1234567890123456789", "1234567890123456789", "12345678901234567890123456789012345678",
  ]
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
    let wide = file.read_decimal128_column("wide")
    let frac = file.read_decimal128_column("wide_frac")
    let varied = file.read_decimal128_column("wide_varied")
    for i in 0..<5 {
      match wide[i] {
        Some(d) => {
          assert_eq(d.unscaled, expected[i])
          assert_eq(d.scale, 0)
        }
        None => fail("expected decimal")
      }
      match frac[i] {
        Some(d) => {
          assert_eq(d.unscaled, expected[i])
          assert_eq(d.scale, 38)
        }
        None => fail("expected decimal")
      }
      match varied[i] {
        Some(d) => {
          assert_eq(d.unscaled, varied_expected[i])
          assert_eq(d.scale, 0)
        }
        None => fail("expected decimal")
      }
    }
    assert_true(wide[5] is None && frac[5] is None)
    let small = file.read_decimal128_column("amount")
    match small[0] {
      Some(d) => {
        assert_eq(d.unscaled, "-999999999999999999")
        assert_eq(d.scale, 4)
      }
      None => fail("expected decimal")
    }
    assert_true(file.read_decimal128_column("all_null")[0] is None)
  }
}

///|
test "PyArrow 38-digit multi-stripe decimals" {
  let magnitude = "99999999999999999999999999999999999999"
  for
    bytes in [
      fixture_decimal_multi_uncompressed(),
      fixture_decimal_multi_zlib(),
      fixture_decimal_multi_snappy(),
    ] {
    let file = open(bytes)
    assert_true(file.stripes.length() > 1)
    let values = file.read_decimal128_column("wide")
    for i in 0..<2000 {
      if i % 7 == 0 {
        assert_true(values[i] is None)
      } else {
        match values[i] {
          Some(d) => {
            assert_eq(
              d.unscaled,
              if i % 2 == 0 {
                magnitude
              } else {
                "-" + magnitude
              },
            )
            assert_eq(d.scale, 0)
          }
          None => fail("expected decimal")
        }
      }
    }
  }
}

///|
test "reject malformed 38-digit decimals" {
  for
    bytes in [
      fixture_bad_decimal_wide_precision(),
      fixture_bad_decimal_wide_negative_precision(),
      fixture_bad_decimal_wide_overflow(),
      fixture_bad_decimal_wide_truncated(),
    ] {
    let rejected = try open(bytes).read_decimal128_column("wide") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
  for
    bytes in [
      fixture_bad_decimal_data(),
      fixture_bad_decimal_scale(),
      fixture_bad_decimal_present(),
      fixture_bad_decimal_precision(),
      fixture_bad_decimal_scale_mismatch(),
      fixture_bad_decimal_bad_schema(),
      fixture_bad_decimal_missing_precision(),
      fixture_bad_decimal_missing_scale(),
      fixture_bad_decimal_overflow(),
      fixture_bad_decimal_trailing(),
    ] {
    let rejected = try open(bytes).read_decimal128_column("amount") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
}
