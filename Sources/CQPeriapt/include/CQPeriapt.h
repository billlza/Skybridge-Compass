// 中文注释：CQPeriapt.h 是 Q-Periapt FFI 的 C 包装伞头（umbrella header）。
//
// 设计动机（mirror OQSRAII）：
//   qperiapt.xcframework 是一个 .binaryTarget，只贡献静态库（libq_periapt_ffi.a）与
//   C ABI 头 q_periapt.h，但 *不* 携带任何 module.modulemap。原因是 liboqs.xcframework
//   已经在共享的 Release/include/ 目录放置了一个 module.modulemap；若 qperiapt 也放置一个，
//   两个 binaryTarget 会同时产出 `.../Release/include/module.modulemap`，触发
//   "Multiple commands produce" 链接前冲突。
//
//   因此我们完全照搬 OQSRAII 的做法：liboqs 通过 C 包装目标 OQSRAII 被消费（Swift 端
//   `import OQSRAII`，而不是 `import liboqs`），SwiftPM 在该目标自有的模块目录里自动生成
//   OQSRAII 模块，不与共享 include 冲突。这里 CQPeriapt 对 QPeriaptFFI 做同样的事：Swift 端
//   改为 `import CQPeriapt`，由 SwiftPM 为本目标自动生成模块映射，xcframework 不再贡献第二个
//   include/module.modulemap。
//
// 该伞头重新导出 q-periapt-ffi 的完整 C ABI（q_periapt_* 符号）。符号本身不变，仅模块名变化。
#pragma once

#include "q_periapt.h"
