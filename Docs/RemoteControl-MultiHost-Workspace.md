# macOS 多主机近距控制

本文保留 2026-09-06 近距工作区初版的范围与验证记录。后续的共享观看、输入权交接及移动端接入见 [共享观看与输入权](RemoteControl-SharedViewing.md)。历史测试数量不代表后续版本的验收结果。

## 产品边界

近距控制采用一个工作区、多个独立会话、单一操作焦点。默认同时连接两台，正在连接的主机也占名额。重复选择已连接设备切换到原会话；达到上限会明确拒绝新连接，不替换其他主机。添加设备页保留现有连接，关闭工作区窗口取消全部连接和待完成操作。

这个范围覆盖 macOS 的 LAN 近距入口。跨网 WebRTC 会话、iOS 界面、多屏同看、批量键鼠广播和双向剪贴板不属于本次实现。不同远端不共享本地解码器、画面或输入队列。当前并发上限是保守的工程边界；提高上限前需要多目标真机资源测量。

会话标签是成熟桌面远控的常见交互：[AnyDesk 的官方会话文档](https://support.anydesk.com/docs/session-settings)说明其 Mac 端用标签呈现会话。[Apple Remote Desktop 的控制和观察说明](https://support.apple.com/guide/remote-desktop/choose-how-to-control-and-observe-apd4f46319e/mac)区分观察与控制。这里选择单焦点操作以明确键鼠和音频的目标；这项设计选择不构成性能对标结果。

## 职责划分

- `ControlledHostSessionPolicy`：共享准入、最近使用焦点和帧率预算的纯规则。
- `ControlledHostWorkspace`：唯一会话所有者，预留容量、协调焦点、隔离连接代次、发布会话状态和失败。每台复用已有 `RemoteControlManager`，不复制握手、协议或解码实现。
- `RemoteControlManager`：一个控制会话的认证连接、解码、帧流和音频接收端；原有被控角色保持其边界。
- `RemoteControlViewerInputDispatcher`：每个会话一条有界、串行的输入队列，最多 256 个在途/待发事件，只合并相邻鼠标移动。单次发送超过 5 秒会终止该会话，避免无限等待。
- `NearFieldWorkspaceViewModel`：窗口操作任务、发现与专属连接的获取；UI 只提交操作和呈现状态。
- `NearFieldMirrorView` / `NearFieldControlCanvas`：会话标签、设备选择、单个引擎的画面。AppKit 输入按真实图像尺寸转换到左上原点的像素坐标，失焦、换画面和拆卸时释放按键和按钮。

## 状态与失败

启动先预留主机键，再创建专属 `NWConnection`。连接不借用发现模块的缓存 socket。取消的创建任务若迟到返回，必须关闭其尚未转移的专属连接。所有后续异步结果都核对条目的确切实例，旧任务不得关闭同 ID 的新会话。

连接状态须在应用层认证与精确流配置 ACK 完成后成为 `connected`。画面展示单独等待实际首帧，不能把 TCP ready 或请求发出当作画面可用。配置 ACK 核对 transaction 和配置中的媒体信息；篡改、错误 ACK、发送失败或超时均为显式失败。

切换焦点按顺序执行：关闭旧会话输入接纳，完成已接收输入和逆序释放，等待旧主机确认后台配置，然后提升新主机，等待其确认，最后开放新主机输入。输入发送失败存在投递不确定性时关闭对应连接，由既有接收端输入所有者在断开时释放状态。不会重试可能已经生效的按键。

失败保留可查看的会话条目和原因，但释放容量及媒体资源。失败记录最多保留一倍并发容量。焦点操作队列最多 16 项，超出时明确拒绝。

## 媒体预算

焦点主机按用户的显示设置工作，音频仅对焦点启用。后台请求 2 FPS（若用户帧率更低则遵循低值），关闭音频，使用不超过 1280×720 的显式尺寸。主机请求解析与编码策略接受 1 FPS 起的合法帧率，避免原有 12 FPS 下限抵消后台预算。

每个引擎持有独立解码器和最后一帧，总资源消耗仍随主机数增加。流配置变化可能重启采集，不能声称零延迟切换、绝不等待关键帧或成本与连接数无关。布局变化保持图像比例，输入使用当前帧的坐标映射。

当前 LAN 显示控件没有会话所属的双向剪贴板、独立光标或交互覆盖层消费者，因此不广告这些能力；光标由主机包含在视频中。音频停止使用现有的精确所有者接口，不允许后台引擎停止焦点引擎的播放。

## 验证与验收

本地行为测试覆盖容量预留、重复连接、焦点屏障、旧任务代次、失败与恢复、独立画面所有者、输入顺序/容量/超时、真实加密 ACK 接收、原生 AppKit 修饰键与失焦释放，以及 loopback 专属 socket 所有权。AppKit 页面截图使用测试会话状态，只证明布局，不证明真实远控。

最终命令与结果以本次执行日志为准。发布前仍须在两个真实目标上验证：同时首帧、快速切换、按键/拖拽释放、后台实际帧率和尺寸、音频交接、其中一台断网、取消后立即重连与关闭窗口；测量 CPU/GPU/内存、上下行带宽、首帧和焦点切换延迟。不得用纯策略测试或构建成功替代这项验收。

## 本地验证记录（2026-09-06）

以下命令在包含本次变更的工作区实际运行。最终测试与产品构建日志均未包含 `error:` 或 `warning:`。

```bash
SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
SKYBRIDGE_UI_TEST_ARTIFACT_DIR=/tmp/skybridge-multi-control-ui \
bash Scripts/run_swift_test_filter.sh \
'ControlledHost|RemoteControl|RemoteDesktopStreamConfigurationTransactionTests|RemoteScreenFrameSendQueueTests|RemoteTexture|LatestTextureDeliveryGateTests|InteractiveRemoteViewTests|NearFieldWorkspacePresentationTests|TrafficPaddingConfigResolutionTests|DeviceDiscoveryManagerOptimizedEndpointTests|SystemAudioCaptureOwnershipTests' \
--disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

swift build --disable-automatic-resolution --disable-prefetching \
--product SkyBridgeCompassApp -Xswiftc -warnings-as-errors

git diff --check
```

- XCTest：283 项通过，0 失败；Swift Testing：1 项通过。合计 284 项。
- 产品构建：通过。
- diff 空白检查：通过。
- 原生 AppKit：14 项输入测试通过；工作区界面及关闭行为另有 3 项测试。已检查 800×600、1000×700 原生渲染图，使用测试会话状态。
- 验证时发现并真修了既有流量填充测试的两处多余 `try`，以及两个测试目标为同一 runner 重复添加运行路径的链接 warning。未削弱断言或关闭诊断。

仅 `_skybridge-rd._tcp` / `_skybridge-remote._tcp` 服务或对应明确端口可进入近距受控主机选择。普通 `_skybridge._tcp` / `_skybridge._udp` 在线记录不能证明主机有远控能力；专属连接也不会借用这些普通服务端口。

最初可用的实物设备为 iPhone 16 Pro 与 iPad Pro 11-inch (M4)。已核对当前 iOS 源码：它们作为 viewer 接收屏幕和 ACK、向电脑发送键鼠；没有 host 采集/广播管线，收到主机侧输入与流请求不执行。升级现有 iOS 包不能补出这项角色，所以这两台设备不能充当本次双受控主机验收拓扑。

双主机真机验收仍未完成。需要两个具备 SkyBridge LAN 受控端及配置 ACK 能力的目标；优先用两台 Mac 复核现有受控端实现。跨平台目标应另核对该平台的 host 实现，不能只依据“在线”或已安装应用推断能力。

后续已补齐 Windows 局域网被控端，并在同网 Windows 真机完成公开身份双向配对、宿主监听、独立桌面采集和输入探针。首轮 Mac 产品连接在 DNS 解析阶段超时：Windows SRV 使用了没有对应地址记录的合成主机名。修复已通过真实 Windows DNS-SD 发布与 Mac `NWConnection` 数据收发探针，但最新 Windows 候选尚未构建部署；该机器随后离线，完整产品画面与键鼠验收仍未通过。独立探针不能替代产品会话，单台 Windows 也不能替代双目标并发验收。

Mac 配对继续复用现有身份、信任存储和协议套件选择；不更换已有身份或绕过握手。连接启动现由私有所有者统一处理 ready、超时、取消与交接，避免外层错误处理重复取消同一 socket。相关 37 项原生回归（含 9 项新增启动竞争用例）通过，0 失败、0 跳过、0 warning/error；签名 Debug 候选已实际启动，正式安装包保持不变。测试结果不代表跨端媒体已通过。
