///|
test "timestamp fraction encoding bounds" {
  assert_eq(timestamp_nanos(0L), 0)
  assert_eq(timestamp_nanos(8L), 1)
  assert_eq(timestamp_nanos(81L), 1000)
  assert_eq(timestamp_nanos(7999999992L), 999999999)
  let high = try timestamp_nanos(8000000000L) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let negative = try timestamp_nanos(-1L) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let expanded = try timestamp_nanos(800000001L) catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  assert_true(high && negative && expanded)
}

///|
test "timestamp malformed streams and types" {
  let seconds = try
    open(fixture_bad_timestamp_seconds()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let nanos = try
    open(fixture_bad_timestamp_nanos()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let present = try
    open(fixture_bad_timestamp_present()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let f = open(fixture_timestamp_v012_uncompressed())
  let wrong = try f.read_timestamp_instant_column("wall") catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let missing = try f.read_timestamp_column("missing") catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let non_utc = try
    open(fixture_bad_timestamp_non_utc()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let no_zone = try
    open(fixture_bad_timestamp_missing_zone()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  let epoch_fraction = try
    open(fixture_bad_timestamp_epoch_fraction()).read_timestamp_column("wall")
  catch {
    Invalid(_) => true
  } noraise {
    _ => false
  }
  // Instant semantics are independent of the writer timezone.
  let instant = open(fixture_bad_timestamp_non_utc()).read_timestamp_instant_column(
    "instant",
  )
  assert_true(instant.length() > 0)
  assert_true(
    seconds &&
    nanos &&
    present &&
    wrong &&
    missing &&
    non_utc &&
    no_zone &&
    epoch_fraction,
  )
}

///|
test "reject PyArrow negative fractional timestamps" {
  for
    bytes in [
      fixture_negative_timestamp_v011(),
      fixture_negative_timestamp_v012(),
    ] {
    let f = open(bytes)
    let wall = try f.read_timestamp_column("wall") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    let instant = try f.read_timestamp_instant_column("instant") catch {
      Invalid(_) => true
    } noraise {
      _ => false
    }
    assert_true(wall && instant)
  }
}
