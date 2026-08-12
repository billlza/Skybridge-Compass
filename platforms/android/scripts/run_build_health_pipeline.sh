#!/usr/bin/env bash
#
# 连续验证管线（Continuous Verification Pipeline）
# ============================================================================
# 任务 2.3 产物 —— _Requirements: 1.3, 1.11_
#
# 目的：以**单次连续调用**验证六个模块的构建健康，作为 W1（依赖升级）与后续
#       检查点（tasks.md 中的 Checkpoint 3 / 19）可重复复跑的唯一入口。
#
# 本管线在一次 Gradle 调用中连续执行下列任务，全部要求退出码 0：
#   - :shared:testDebugUnitTest            :shared:lintDebug
#   - :core:testDebugUnitTest              :core:lintDebug
#   - :app:testDebugUnitTest               :app:lintDebug
#   - :device-discovery:testDebugUnitTest  :device-discovery:lintDebug
#   - :file-transfer:testDebugUnitTest     :file-transfer:lintDebug
#   - :remote-control:testDebugUnitTest    :remote-control:lintDebug
#   - :app:assembleDebug
#
# 硬约束（R1.3，本脚本刻意不提供任何绕过开关）：
#   * 不排除任务（无 -x / --exclude-task）
#   * 不跳过测试（不设置 -x test，不注入 test.enabled=false）
#   * 不删除既有测试
#   * 不关闭 lint 失败中断（不设置 abortOnError=false）
#   * 七个子项目的配置阶段均须成功
#
# 用法：
#   scripts/run_build_health_pipeline.sh                 # 连续执行全部验证任务
#   scripts/run_build_health_pipeline.sh --warning-mode-all
#                                                        # 以 --warning-mode all 复跑（任务 2.4）
#   scripts/run_build_health_pipeline.sh --offline       # 追加 --offline
#
# 退出码：
#   0  全部任务退出码 0（全绿）
#   非 0  任一任务失败；失败时按 R1.11 的二分回退指引处置（见文末「二分回退」）。
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WARNING_MODE_ALL="false"
EXTRA_GRADLE_ARGS=()

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --warning-mode-all)
      WARNING_MODE_ALL="true"
      shift
      ;;
    --offline)
      EXTRA_GRADLE_ARGS+=("--offline")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      # 透传其它 Gradle 参数（例如 --stacktrace），但绝不允许绕过约束的开关。
      case "$1" in
        -x|--exclude-task|*abortOnError*|*test.enabled*)
          echo "拒绝的参数（违反 R1.3 硬约束，不得绕过任务/测试/lint）：$1" >&2
          exit 2
          ;;
      esac
      EXTRA_GRADLE_ARGS+=("$1")
      shift
      ;;
  esac
done

# 六个模块，顺序：依赖被依赖方在前（shared → core → 叶子模块）。
MODULES=(
  ":shared"
  ":core"
  ":app"
  ":device-discovery"
  ":file-transfer"
  ":remote-control"
)

# 组装单次连续调用的任务列表：六模块 testDebugUnitTest + lintDebug，加 :app:assembleDebug。
GRADLE_TASKS=()
for module in "${MODULES[@]}"; do
  GRADLE_TASKS+=("${module}:testDebugUnitTest" "${module}:lintDebug")
done
GRADLE_TASKS+=(":app:assembleDebug")

GRADLE_FLAGS=("--no-daemon" "--stacktrace")
if [[ "$WARNING_MODE_ALL" == "true" ]]; then
  GRADLE_FLAGS+=("--warning-mode" "all")
fi

echo "============================================================================"
echo "SkyBridge Compass Android — 连续验证管线（任务 2.3 / R1.3）"
echo "----------------------------------------------------------------------------"
echo "工作目录 : $ROOT_DIR"
echo "警告模式 : $([[ "$WARNING_MODE_ALL" == "true" ]] && echo '--warning-mode all（任务 2.4）' || echo '默认')"
echo "任务序列 : ${GRADLE_TASKS[*]}"
echo "约束     : 不排除任务 / 不跳过测试 / 不删测试 / 不关闭 lint 失败中断"
echo "============================================================================"

set +e
./gradlew "${GRADLE_TASKS[@]}" "${GRADLE_FLAGS[@]}" ${EXTRA_GRADLE_ARGS[@]+"${EXTRA_GRADLE_ARGS[@]}"}
PIPELINE_EXIT=$?
set -e

echo "----------------------------------------------------------------------------"
if [[ "$PIPELINE_EXIT" -eq 0 ]]; then
  echo "连续验证管线全绿（全部任务退出码 0）。"
else
  cat >&2 <<'EOF'
连续验证管线失败（退出码非 0）。

二分回退指引（R1.11）：
  1) 单依赖回退：把最可疑的单个升级坐标在 gradle/libs.versions.toml 中回退到
     dependency-inventory.md 第 6 节记录的「当前已声明版本」，重跑本管线。
  2) 组合回退：若单依赖回退仍失败，逐步把本轮全部升级坐标一并回退到最近一次
     全绿的版本组合，重跑本管线直至全绿。
  3) 在 dependency-inventory.md 第 6 节把该失败坐标的阻塞类别改记为
     `编译或 API 不兼容 (COMPILE_OR_API_INCOMPATIBLE)` 或
     `升级后任务失败 (TASK_FAILED_AFTER_UPGRADE)`，附失败的 Gradle 任务名。
EOF
fi
echo "============================================================================"

exit "$PIPELINE_EXIT"
