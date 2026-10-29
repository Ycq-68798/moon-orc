// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Ycq-68798/moon-orc"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/Ycq-68798/moon-orc"

license = "Apache-2.0"

keywords = [ ]

preferred_target = "wasm"

description = "ORC integer and string reader with ZLIB and Snappy support"

import {
  "moonbitlang/x@0.5.5",
  "mizchi/zlib@0.4.10",
}
