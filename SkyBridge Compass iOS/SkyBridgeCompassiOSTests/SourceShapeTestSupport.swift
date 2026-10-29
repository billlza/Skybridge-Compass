import Foundation
import XCTest

/// 读取仓库源码用于“源码形状”断言测试。
///
/// 真机测试沙箱内不挂载仓库文件，此时显式跳过（XCTSkip）而不是误报失败；
/// 在 macOS / iOS 模拟器上文件缺失说明测试路径写错，必须按错误抛出。
func readRepositorySourceForSourceShapeTests(at sourceURL: URL) throws -> String {
  if FileManager.default.fileExists(atPath: sourceURL.path) {
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
  #if os(iOS) && !targetEnvironment(simulator)
    throw XCTSkip(
      "Repository source files are not mounted inside the physical-device test sandbox; run source-shape tests on macOS or iOS Simulator."
    )
  #else
    return try String(contentsOf: sourceURL, encoding: .utf8)
  #endif
}
