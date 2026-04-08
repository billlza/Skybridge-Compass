#!/usr/bin/env bash

skybridge_package_build_source() {
  local build_dir="$1"
  local xcode_build_dir="$2"
  local swiftpm_release_build_dir="$3"

  if [[ "$build_dir" == "$xcode_build_dir" ]]; then
    echo "xcode_release"
    return 0
  fi

  if [[ "$build_dir" == "$swiftpm_release_build_dir" ]]; then
    echo "swiftpm_release"
    return 0
  fi

  echo "unknown"
}

skybridge_assert_package_build_policy() {
  local package_context="$1"
  local build_source="$2"

  if [[ "$package_context" == "release_dmg" && "$build_source" == "swiftpm_release" ]]; then
    cat >&2 <<'EOF'
错误：发布 DMG 禁止使用 SwiftPM release fallback 产物打包。
请先完成 Xcode Release 构建，再重新运行 package_app.sh / build_dmg.sh。
EOF
    return 1
  fi

  return 0
}
