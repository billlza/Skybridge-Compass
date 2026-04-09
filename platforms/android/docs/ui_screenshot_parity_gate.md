# Android UI 截图差分门禁与真机矩阵

## 目标
- 提供可重复的 Android 真机截图采集矩阵。
- 提供像素级差分门禁（默认 strict：0 容差）。

## 脚本
- 采集矩阵：`scripts/android_device_matrix_capture.sh`
- 差分门禁：`scripts/screenshot_diff_gate.sh`
- 差分引擎：`scripts/visual_diff_gate.py`

## 1) 真机矩阵采集
```bash
bash scripts/android_device_matrix_capture.sh
```

默认行为：
- 构建并安装 debug APK 到所有已连接设备。
- 对固定路由逐页截图：
  - `dashboard`
  - `device_discovery`
  - `file_transfer`
  - `remote_control`
  - `settings`
  - `settings/device_auth`
  - `settings/encryption`
  - `settings/access_control`
  - `settings/privacy`
  - `settings/webrtc`
  - `settings/help`
  - `settings/feedback`
  - `settings/licenses`
  - `settings/version`
- 输出目录：`artifacts/screenshots/android/actual/<serial>/*.png`
- 同步输出设备矩阵：`artifacts/screenshots/android/actual/matrix.csv`

常用参数：
```bash
# 仅指定设备
bash scripts/android_device_matrix_capture.sh --devices "emulator-5554,R5CX..."

# 仅采集核心页面
bash scripts/android_device_matrix_capture.sh --routes "dashboard,device_discovery,settings"

# 已有 APK，跳过构建
bash scripts/android_device_matrix_capture.sh --no-build --apk-path app/build/outputs/apk/debug/app-debug.apk
```

## 2) 像素级差分门禁
```bash
bash scripts/screenshot_diff_gate.sh \
  --baseline-dir artifacts/screenshots/android/baseline \
  --actual-dir artifacts/screenshots/android/actual
```

默认阈值（strict）：
- `max_diff_ratio=0.0`
- `max_mean_delta=0.0`
- `max_channel_delta=0`
- `pixel_tolerance=0`

输出：
- `artifacts/screenshots/android/diff/summary.json`
- `artifacts/screenshots/android/diff/report.md`
- `artifacts/screenshots/android/diff/diffs/**/*_diff.png`（含热力图）

## 3) 一键采集 + 门禁
```bash
bash scripts/screenshot_diff_gate.sh \
  --baseline-dir artifacts/screenshots/android/baseline \
  --capture-first
```

## 依赖
- `adb`
- `python3`
- `Pillow`（`python3 -m pip install pillow`）

