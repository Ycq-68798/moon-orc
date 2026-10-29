///|
fn main {
  let args = @env.args()
  if args.length() != 2 {
    println("Usage: moon run cmd/main --target native -- <file.orc>")
    return
  }
  let data = try! @fs.read_file_to_bytes(args[1])
  let file = try! @orc.open(data)
  println("Rows: \{file.rows}")
  println("Stripes: \{file.stripes.length()}")
  println("Schema:")
  let root = file.types[0]
  for i in 0..<root.names.length() {
    let column = root.children[i]
    println("  \{root.names[i]}: ORC type \{file.types[column].kind}")
  }
}
