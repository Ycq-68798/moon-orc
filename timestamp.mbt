///|
/// A timestamp represented without nanosecond overflow: `seconds` is the
/// floor whole second and `nanosecond` is in the range 0..999,999,999.
pub(all) struct OrcTimestamp {
  seconds : Int64
  nanosecond : Int
}

///|
fn timestamp_nanos(encoded : Int64) -> Int raise OrcError {
  if encoded < 0L {
    raise Invalid("negative timestamp nanoseconds")
  }
  let zeros = (encoded & 7L).to_int()
  let mut nanos = encoded >> 3
  if zeros != 0 {
    for _ in 0..<(zeros + 1) {
      if nanos > 99999999L {
        raise Invalid("timestamp nanoseconds exceed one second")
      }
      nanos *= 10L
    }
  }
  if nanos > 999999999L {
    raise Invalid("timestamp nanoseconds exceed one second")
  }
  nanos.to_int()
}

///|
fn timestamp_writer_timezone(
  file : OrcFile,
  stripe : Stripe,
) -> String raise OrcError {
  let start = stripe.offset + stripe.index_length + stripe.data_length
  let footer = decompress_stream(
    file.bytes[start:start + stripe.footer_length].to_owned(),
    file.compression,
    file.block_size,
  )
  for field in fields(footer) {
    if field.number == 3 && field.wire == 2 {
      return @utf8.decode(field.bytes) catch {
        _ => raise Invalid("invalid writer timezone")
      }
    }
  }
  raise Invalid("missing timestamp writer timezone")
}

///|
fn read_timestamps(
  file : OrcFile,
  name : String,
  expected_kind : Int,
) -> Array[OrcTimestamp?] raise OrcError {
  let column = primitive_column(file, name, expected_kind)
  let out : Array[OrcTimestamp?] = []
  for stripe in file.stripes {
    if stripe.rows > file.rows - out.length() {
      raise Invalid("stripe row count exceeds footer")
    }
    if expected_kind == 9 {
      let zone = timestamp_writer_timezone(file, stripe)
      if zone != "UTC" &&
        zone != "GMT" &&
        zone != "Etc/UTC" &&
        zone != "Etc/GMT" {
        raise Invalid("non-UTC timestamp writer timezone is not supported")
      }
    }
    let (ss, encodings) = streams(file, stripe)
    if column >= encodings.length() {
      raise Invalid("missing column encoding")
    }
    let encoding = encodings[column].kind
    if encoding != 0 && encoding != 2 {
      raise Invalid("unsupported timestamp encoding")
    }
    let present = match get_stream(file, ss, column, 0) {
      Some(data) => bits(data, stripe.rows)
      None => [ for _ in 0..<stripe.rows => true ]
    }
    let count = present_count(present)
    let seconds_data = get_stream(file, ss, column, 1).unwrap_or(b"")
    let nanos_data = get_stream(file, ss, column, 5).unwrap_or(b"")
    let seconds = if encoding == 0 {
      int_rle(seconds_data, count)
    } else {
      int_rle_v2(seconds_data, count)
    }
    let nanos = unsigned_rle(nanos_data, count, encoding == 2)
    let mut index = 0
    for p in present {
      if p {
        let fraction = timestamp_nanos(nanos[index])
        let unix_seconds = add_signed(seconds[index], 1420070400L)
        // Legacy producers disagree about pre-epoch fractional encoding. At
        // epoch second zero, that representation can also be ambiguous.
        if unix_seconds <= 0L && fraction != 0 {
          raise Invalid(
            "pre-epoch or epoch-second fractional timestamp is not supported",
          )
        }
        // Legacy ORC files may use the hybrid Julian/Gregorian calendar.
        if unix_seconds < -12219292800L {
          raise Invalid("timestamps before 1582-10-15 are not supported")
        }
        out.push(Some({ seconds: unix_seconds, nanosecond: fraction, }))
        index += 1
      } else {
        out.push(None)
      }
    }
  }
  if out.length() != file.rows {
    raise Invalid("stripe row count does not match footer")
  }
  out
}

///|
/// Read an ORC TIMESTAMP as wall-clock seconds and nanoseconds, represented
/// relative to 1970-01-01 as if UTC. Only UTC/GMT writer timezones are accepted;
/// this wall-clock value does not itself specify an instant or timezone.
pub fn OrcFile::read_timestamp_column(
  file : OrcFile,
  name : String,
) -> Array[OrcTimestamp?] raise OrcError {
  read_timestamps(file, name, 9)
}

///|
/// Read an ORC TIMESTAMP_INSTANT as UTC seconds and nanoseconds since 1970-01-01.
pub fn OrcFile::read_timestamp_instant_column(
  file : OrcFile,
  name : String,
) -> Array[OrcTimestamp?] raise OrcError {
  read_timestamps(file, name, 18)
}
