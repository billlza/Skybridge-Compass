// 中文注释：cqperiapt.c 是一个空翻译单元（mirror OQSRAII/src），仅用于让 CQPeriapt 成为可构建目标。
//
// 真正的实现来自 QPeriaptFFI（qperiapt.xcframework 的静态库 libq_periapt_ffi.a），通过包装目标
// 依赖链接进来。本文件只是给 SwiftPM 一个可编译的源文件，从而让 SwiftPM 在本目标自有模块目录里
// 自动生成 module map（mirror OQSRAII），避免 qperiapt.xcframework 再贡献第二个
// include/module.modulemap。
#include "CQPeriapt.h"
