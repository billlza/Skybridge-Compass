fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac setup_certificates

```sh
[bundle exec] fastlane mac setup_certificates
```

获取或创建 Developer ID 证书

### mac build_signed

```sh
[bundle exec] fastlane mac build_signed
```

低层步骤：构建并签名带 Widget 的 Developer ID .app（Apple 登录采用 web_session，不生成最终 DMG）

### mac notarize_app

```sh
[bundle exec] fastlane mac notarize_app
```

低层步骤：仅公证现有 .app（不生成最终 DMG）

### mac release

```sh
[bundle exec] fastlane mac release
```

最终 Developer ID 发布链：构建、签名、公证 .app/.dmg，Apple 登录固定走 web_session，并执行严格 release readiness 校验

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
