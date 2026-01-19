# SkyBridge Compass Pro (macOS)

SkyBridge Compass Pro 是面向 macOS 的设备管理与远程控制应用。本仓库已精简为仅包含 macOS 相关源码与论文资料。

## 目录结构

- `Sources/`：macOS 应用与核心模块源码
- `Sources/Vendor/`：随项目分发的第三方框架
- `Tests/`：测试用例
- `Docs/`：论文与图表素材

## 环境要求

- macOS 14+
- Xcode 15+
- Swift 6.2+（由 Xcode 版本提供）

## 构建与运行

1. 用 Xcode 打开 `Package.swift`
2. 选择 `SkyBridgeCompassApp` 作为运行目标
3. 直接运行

命令行测试：

```bash
swift test
```

## 论文与 PDF 源码位置

- 主论文 LaTeX：`Docs/IEEE_Paper_SkyBridge_Compass_patched.tex`
- Supplementary LaTeX：`Docs/supplementary.tex`
- 一键编译脚本：`./compile_paper.sh`（会自动生成 figures + 编译主论文和 Supplementary）

## 可复现实验（Artifact 复核）

论文中标注的 artifact 信息如下（供 reviewer/编辑核对）：

- URL：`https://github.com/billlza/Skybridge-Compass`
- Tag：`artifact-v1`
- Commit：`8a68fa6e0fe78147d2b18d3287681f5d07c74afd`

Source archive checksums（immutability 辅助证据）：

- `artifact-v1.zip`：`SHA256=354443f7cda3e25a51480a683da1712a8ea9588a2bc510f4f716bd553d6d72ac`
- `artifact-v1.tar.gz`：`SHA256=90228458587f095e9cd403d3d449f885a2b8b002057a76e6f60c291e45071388`

最小复核流程（需要本机已安装 Xcode/Swift 与 TeXLive；PQC SDK 仅在 macOS 26+ 可用）：

```bash
git clone https://github.com/billlza/Skybridge-Compass
cd Skybridge-Compass
git checkout artifact-v1

git rev-parse HEAD
git describe --tags --always

# 复现论文 PDF（主论文 + Supplementary）
bash ./compile_paper.sh

# 运行论文评测与生成 CSV/图表
bash Scripts/run_paper_eval.sh
```

多批次（独立进程）性能统计复核：

```bash
SKYBRIDGE_BENCH_BATCHES=5 bash Scripts/run_paper_eval.sh
```

## 真实网络小规模验证（仅需一台 Mac，可选）

如果你想补充 reviewer 关心的真实 NAT / 异构接入网络 / mobility 的“小规模实测”，但手头只有一台 Mac：

1. 在不同网络下分别运行一次 STUN 探测脚本（例如：家庭 Wi‑Fi、手机热点、不同运营商/不同地点）。
2. 脚本会记录当前网络路径（是否 expensive/constrained）、本地 UDP 端口、STUN 映射端点、RTT 分布与丢包率（超时）。
3. 输出 CSV 到 `Artifacts/`，可直接汇总到 supplementary 表格或作为外部有效性补充材料。

运行示例：

```bash
swift Scripts/run_real_network_probe.swift --label home_wifi --samples 50
# 切换网络后再跑一遍（mobility / 异构网络）
swift Scripts/run_real_network_probe.swift --label phone_hotspot --samples 50
```

输出文件：

- `Artifacts/realnet_stun_samples_<timestamp>_<label>.csv`
- `Artifacts/realnet_stun_summary_<timestamp>_<label>.csv`

预期输出（关键点）：

- `git rev-parse HEAD` 应为 `8a68fa6e0fe78147d2b18d3287681f5d07c74afd`
- `git describe --tags --always` 应输出 `artifact-v1`（或等价形式如 `artifact-v1-0-g8a68fa6`）
- 生成的 PDF：`Docs/IEEE_Paper_SkyBridge_Compass_patched.pdf` 与 `Docs/supplementary.pdf`
- CSV 输出目录：`Artifacts/`

## Release 校验

当前目录下 DMG 构建产物（本地）：

- `dist/SkyBridgeCompassPro-1.0.2.dmg`：`SHA256=312a4ca61142afd8b6cf6e6f2d0993a40c51e3cc0ef7ecc12608e07a76c001de`

## 说明

仓库不包含构建产物与敏感配置（密钥、证书、运行时凭据等），相关内容已加入忽略规则。
