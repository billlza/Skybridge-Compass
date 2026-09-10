# Windows 局域网被控端

Windows 远控宿主接入 Mac 近距多设备工作区。宿主默认关闭；用户交换公开配对信息、确认控制器身份并选择局域网后才开启。每次连接还需要本机批准。最多两台已批准设备同时观看，一次只有一台拥有 Windows 桌面输入；输入权由本机明确移交。Mac 可为不同受控主机持有独立连接，焦点切换时释放原主机的按键，并为后台主机降低画面预算。

## 模块边界

- `ProductHandshakeCore` / `ProductHandshakeKeyDerivation`：与载体无关的 MessageA、MessageB、Finished 状态机和密钥派生。原 WebRTC driver 保留为既有载体的适配器。
- `RemoteControlHandshakeBinding`：将签名覆盖的 SOA 发起者和目标映射到明确导入的可信设备；IP、设备名称和 Bonjour TXT 都不能授予控制权限。
- `RemoteControlIdentityStore`：稳定设备身份、ML-DSA-65 / ML-KEM-768 密钥与控制器信任表。复用当前用户 DPAPI 和既有原子文件提交机制，独占文件租约阻止两个进程覆盖同一身份。损坏、解密失败和冲突不会重建身份或返回空信任表。
- `WindowsRemoteControlHost`：显式开启、监听与 DNS-SD 注册、最多两个独立连接、关闭和失败后的精确资源清理。
- `RemoteControlHostAccessCoordinator`：从 TCP 接纳到完成清理的容量、待审批会话、唯一输入所有者和有序移交事务。几何映射和流配置不授予输入权。
- `RemoteControlHostSession`：一条 TCP 流贯穿握手和已认证控制阶段；验证配置、返回事务确认或拒绝、处理输入与画面展示回执。
- `WindowsRemoteControlStream`：一个配置对应的一组采集、编码、音频和输入资源。准备成功之前不发送成功确认，旧资源退出之前不创建替代资源。
- `WindowsDesktopCapture` / `WindowsDesktopScaler` / `WindowsDesktopEncoder` / `WindowsRemoteInput`：DXGI 桌面复制、同设备 GPU 缩放、Media Foundation H.264、Windows 输入注入的原生适配层。
- `WindowsLoopbackAudioSource` / `WindowsOpusAudioEncoder`：WASAPI 默认系统输出回环与 48 kHz 双声道 Opus。
- `WindowsRemoteControlHostWorkspace` / `RemoteControlHostViewModel`：应用服务与 UI 状态投影。WinUI 控件不访问套接字、身份文件或原生采集对象。

## 连接与信任

配对材料只包含稳定设备 ID、显示名称、带明确算法的公开身份公钥及其协议指纹、公开 KEM 密钥。它不包含私钥、账号 token 或解密凭据。导入由用户明确授权；同一身份重复导入幂等，身份、公钥或 KEM 冲突必须拒绝。

持久化的是授权边界，因此与私钥一起使用已有 DPAPI。这里防御的是另一 Windows 用户离线读取私钥或改变控制器授权表；不新增独立签名、哈希审计链或网络身份旁路。显式配对只授予后续认证资格，每次连接仍验证协议签名、SOA 目标和 Finished。

粘贴配对材料后先显示控制器名称与协议指纹，用户点击“信任此控制器”才提交同一份已预览材料。导入信任和刷新网卡时，UI 保持集合及未变化条目的引用稳定；网卡顺序或名称变化不会清除仍有效的选择。适配器、接口索引或地址发生变化时清除失效选择；只剩一个可用网络时自动选中，尚无有效选择且有多个网络时要求明确选择。开启前重新检查所选网络是否仍可用；宿主开启期间需先停止，再刷新或切换网卡。

服务发布 `_skybridge-rd._tcp`。SRV 目标使用 `GetComputerNameExW(ComputerNamePhysicalDnsHostname)` 返回的 Windows 实际 DNS 主机名并追加 `.local`，不从配对显示名或设备 UUID 构造别名。保留合法 Unicode 名称，按 UTF-8 检查每个标签最多 63 字节和主机名总长，避免转换为系统没有发布的名称。SRV 端口必须等于实际 TCP listener 端口；TXT 严格使用版本 2 的四个字段：`version`、`deviceId`、`pubKeyFP`、`platform=windows`，总长不超过 200 字节。

注册回调成功后才进入监听状态；取消中返回的注册结果仍由原注册实例撤销。注册成功本身不能证明目标主机有 A/AAAA 记录：早期候选曾成功发布指向 UUID 别名的 SRV，但 Mac 无法解析该别名。DNS 验收必须逐层检查 SRV、目标地址和实际 TCP 连接；当前实际主机名方案已通过独立跨机器探针，完整产品会话状态见文末。

## 多个观看会话与输入权

连接名额在接收 TCP 连接时预留，因此握手、等待配置、等待审批和已连接会话合计最多两个。一个连接的解码/配置、采集、编码、音频、输入状态和清理都属于自己的实例。未经本机批准，不准备桌面资源、不发送成功配置确认，也不允许输入。审批窗口显示每台设备的角色，提供允许观看、允许控制、移交输入和拒绝/断开的原生命令；窗口可调整大小并滚动。

支持多会话授权的控制端在配置中声明 `remoteControlAccessVersion: 1`。初始配置确认中的 `controlAccess` 包含 `version`、单调 `revision`、`role` 和控制者独有的 `lease`。之后的权限更新使用独立的 `controlAccess` 消息，不冒充另一个流配置事务的确认。`mouseEvent` / `keyboardEvent` 的消息外壳必须携带当次授权的 `inputControlLease`；观察者、旧授权代次和伪造 lease 都不能调用 Windows 输入适配器。旧控制端没有该协商能力时只允许独占控制，不能和其它观看会话混用，也不提供其无法表达的“仅观看”模式。

输入移交先关闭旧输入权，再释放原会话持有的按键和按钮，发送撤权通知，最后发布新的授权。新 lease 不复用旧值。整个事务的串行屏障覆盖网络等待和失败返回；移除旧连接不会释放正在进行的事务。收到新授权后立即到达的输入在同一屏障后等待本地提交，避免丢失首个按键。释放失败时禁止任何新输入权，保留确切待清理资源，待恢复交互桌面后由停止操作重试。失败的撤权不会断开尚未改变权限的其它观看者。

两个独立采集/编码实例会增加资源消耗；本次没有宣称共享编码或固定资源成本。提高两个会话的上限前需要真实 Windows CPU、GPU、内存和带宽测量。Windows 控制端的 `RemoteDesktopWorkspaceClient` 目前仍明确禁用实际连接、全屏和断开操作，缺少真实观看传输、解码和输入管线；本次宿主改进不能视为 Windows 控制端一控多完成。

## 配置与媒体

控制消息使用 SBRC；视频使用 SBRF v2 的 H.264 Annex-B，首个关键帧携带 SPS/PPS。音频使用 `pqc-media-v1`，当前 SBMA wire version 为 2。音频计数器和样本时间轴属于认证会话，停止和重新开启音频不得重置 nonce 或令样本时间倒退；同一采集周期内的真实间隔保持不变。

配置事务遵循有序载体：相同事务、相同有效配置返回相同确认，不重复创建资源；相同事务改变配置属于协议错误。资源准备或确认发送最多等待 30 秒。成功确认之前必须实际采集并编码出首个关键帧，确认之后才发送该帧并允许输入。停止配置必须先停止媒体并释放输入，再确认停止。

已知准备失败返回绑定原事务的 `streamConfigurationRejected`，由 Mac 显示明确原因。拒绝不能确认另一个事务，也不能把失败伪装成已连接。无默认系统音频输出对应 `audio-device-unavailable`；用户可以接入输出设备，或在现有远程桌面设置关闭声音后重新连接。程序不自动换声音设备、不发送假静音、不自动修改用户设置。

音频目的地址必须对应认证 TCP 对端。Mac 使用 `0.0.0.0` / `::` 表示接收端监听地址时，仅接受与 TCP 地址族匹配的占位值，实际发送始终使用 TCP 对端地址，不把占位值当目的地。

当前编码器为系统 H.264 软件编码器；DXGI 采集使用 Direct3D 11。不能将 `enableHardwareAcceleration` 偏好宣称为已启用 GPU 视频编码。自动分辨率按最大 1920×1080 的软件编码预算启动，显式高分辨率请求保持原意。后台配置支持真实 2 FPS 与最大 1280×720；尺寸转换保留宽高比。编码、音频队列和未完成帧均有容量限制，发送超时会结束准确的原连接，不重试已发送部分字节的 TCP 帧。

启用硬件加速时，采集器在原 D3D11 设备上完成旋转和缩放，只将目标分辨率的像素读回内存，避免每帧搬运完整 5K 桌面。关闭该偏好时使用原 CPU 转换路径；不支持所需 GPU 能力会明确报错，不静默换路径。桌面输入仍按物理显示器坐标映射；光标按实际输出尺寸合成。首次只有光标变化的 DXGI 回调不代表有效桌面帧，必须在准备期限内收到真实桌面呈现。

每条 TCP 连接开启系统存活检测：空闲 10 秒后按 3 秒间隔探测，最多重试 3 次。它用于让断网且没有新画面的控制器最终释放宿主槽位，不改变系统网络设置，也不新增应用层心跳协议。实际断开时刻仍由系统 TCP 调度决定。

Windows 的“设置 → 高级 → 启用实时天气”同时控制动态背景绘制。关闭后保留静止背景；尺寸或天气条件变化只重绘一帧，开启后恢复动画。原有背景着色器和天气数据的手动刷新方式保持不变。

## 输入与停止

只对活动的交互用户桌面采集和注入，不在 SSH 的 Session 0、锁屏或安全桌面中尝试操作，不切换桌面或绕过应用完整性等级。`SendInput` 的短写按成功前缀记录所有权，失败向调用者报告。UIPI 不能仅凭零返回值精确诊断，因此界面不伪称已经确定具体阻挡原因。

画面坐标以 `Width - 1` / `Height - 1` 归一化，再映射到物理显示器及完整虚拟桌面，使缩小后的首、末像素仍能到达桌面两端。旧的宽高除数会让右、下边缘不可达。输入必须满足 `0 ≤ x < Width`、`0 ≤ y < Height`；最后一个像素内部的有效小数坐标映射到边缘，非有限值、负值和越界值直接拒绝，不将越界事件夹入有效区域。负原点显示器和 DPI 不改变物理坐标语义。

Mac 修饰键按独立物理按下/抬起处理；Fn 的功能层映射在同一输入所有者中记录，释放时使用按下时的实际绑定。停止按逆序释放本会话拥有的按键和鼠标键，不释放本地用户先前已按下的键。

媒体线程退出后才清除会话密钥。若锁屏导致输入释放失败，保留原输入所有者，拒绝新控制器接管，并允许恢复桌面后再次停止。历史运行错误只报告一次，不能让已完成清理的窗口永远无法关闭；清理失败本身必须保留待处理资源。

## 验证

纯协议测试中的 Mac vectors 由当前 Swift 生产 KDF、Finished、SBRC 和 SBMA 源码导出：

```sh
python3 Scripts/export-mac-remote-control-vectors.py <MacRepo> windows/Skybridge.WinClient.ContractTests/Fixtures/remote-control-mac-wire-v1.json
dotnet run --project windows/Skybridge.WinClient.ContractTests/Skybridge.WinClient.ContractTests.csproj -p:TreatWarningsAsErrors=true
pwsh -NoProfile -File Scripts/verify-windows-stack-freshness.ps1 -EvidencePath <evidence.json>
```

Windows 上同一测试入口强制使用真正的 ML-DSA、ML-KEM 和 DPAPI。其它平台的显式不支持分支、协议向量或 mock 输入平台都不能作为 Windows 原生功能通过的依据。

当前 Rust 1.97 的本地化 MSVC 链接器信息会触发上游 `linker_messages` 回归（[Rust #159133](https://github.com/rust-lang/rust/issues/159133)）。本地验证可在当前构建进程选择同版本工具链自带的 MSVC ABI 链接器，不改变警告等级或覆盖已有 Rust flags：

```powershell
$sysroot = (& rustc --print sysroot).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Rust sysroot.' }
$windowsRustLinker = Join-Path $sysroot 'lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe'
if (!(Test-Path -LiteralPath $windowsRustLinker -PathType Leaf)) { throw 'Bundled Rust linker not found.' }
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = $windowsRustLinker
dotnet build windows/Skybridge.WinClient/Skybridge.WinClient.csproj -c Debug -p:TreatWarningsAsErrors=true
```

真实桌面验证必须在登录用户的交互会话运行，捕获应用窗口、采集像素、可解码视频、输入后果、实际退出状态和日志。原生适配器 smoke 与 Mac → Windows 产品会话验收是独立检查；单台 Windows 的通过也不能替代两个不同受控设备的并发验收。

## 当前验收状态（2026-09-06）

| 验证对象 | 已取得的证据 | 当前边界 |
| --- | --- | --- |
| R3 Windows 候选 | WinUI 与 Rust 完整构建为 0 errors / 0 warnings；该候选 Windows 原生契约测试 146 PASS | 仅适用于 R3，不覆盖后续网卡选择、DNS 主机名和首末像素修复 |
| R5 本地源码 | 完整契约测试 159 PASS，0 errors / 0 warnings，包含稳定网卡选择、DNS 名称校验和缩放后边缘坐标回归 | 在非 Windows 主机运行，不能代替 R5 的 Windows 原生 PQC、DPAPI、WinUI 构建或真实输入验证 |
| 实际 DNS 主机名方案 | 最终发布适配器的独立临时服务经 Mac 完成 SRV 解析、目标地址解析、Network.framework TCP 连接及预期载荷接收；Windows 完成异步注销，后续查询不再返回该服务 | 证明发布与传输路径；尚未证明完整产品认证、视频与输入会话通过 |
| 桌面原生适配器 | 独立交互会话探针完成真实桌面采集、H.264 编码与测试窗口输入 | 后续 R5 的首末像素修复尚未在真实产品会话验收 |
| Mac → Windows 产品会话 | 已交换公开配对材料并持久化控制器信任；第一轮实际连接停在 DNS 解析超时 | 正向产品视频与输入尚未通过，需使用两端最新候选重新验收 |
| 系统声音 | 测试主机没有活动系统播放端点；缺失输出设备的显式拒绝与 Opus 样本编解码有契约测试 | WASAPI 真实声音采集、传输和 Mac 播放尚未通过 |
| Mac 一控多 | 已有独立会话及前后台配置的实现与回归 | 两台不同受控设备的并发、焦点切换输入释放及画面预算仍待真机验收 |

R5 源码包尚未成功上传，也未在 Windows 构建。最近一次验证中，Windows 主机离线，直连 SSH 不可用，现有中继端口也没有监听；远端构建与产品验收因此暂停。恢复连接后应先核对候选源码，再完成 Windows 构建和原生测试，随后验证实际 Mac 会话及双目标并发。当前状态不能作为功能发布或端到端验收通过的依据。

## 多会话本地验证（2026-09-07）

`.NET 10.0.302` 的完整 `ContractTests` 构建使用 `-warnaserror`，0 错误、0 警告；运行取得 175 PASS，另有 67 条协议断言和 14 条身份断言。新增覆盖本机审批前不采集、两个真实加密控制会话的独立流、观察者输入拒绝、授权移交与旧 lease 拒绝、协商降级拒绝、发送与本地提交竞争、旧连接移除时的移交屏障、正在提交输入时的审批与移交等待、等待取消、交付结果不确定时只断开发送失败的会话、清理失败保留容量以及每行 UI 命令的会话身份。

本次未取得 Windows 交互会话的 WinUI 构建、启动、双控制者画面/输入及音频证据。macOS 上默认产品构建遇到 `NETSDK1100`；显式启用 Windows targeting 后仍不能执行 Windows 的 `XamlCompiler.exe`。XML 和资源键检查只证明文件结构，不证明原生窗口可用。发布与跨平台真机验收门槛保持未通过。

## Windows handshake and packaging update (2026-09-08)

The Windows responder now accepts the `0x0102` ML-KEM-768 / ML-DSA-65 forward
secure suite used by the current Mac initiator. It authenticates MessageA,
performs ephemeral X25519 through the existing Rust cryptographic dependency,
and combines the static and ephemeral secrets using the Mac v2 transcript and
suite-bound HKDF contract. MessageB signs its responder contribution, and both
Finished messages remain mandatory. Low-order X25519 inputs fail explicitly.
The existing `0x0101` initiator/diagnostic path remains unchanged; this update
must not be described as a full Windows initiator migration.

The Rust C ABI exposes a bounded 32-byte X25519 operation, with RFC 7748 vectors
and malformed/low-order input tests. WinUI and the native contract project share
`windows/NativeCore.targets`, so the tests carry an actual Core library beside
their executable. Windows native tests exercise a v2-only offer, contribution
binding, signature verification, Finished and symmetric session keys.

ICO and MSIX assets now use the shared product artwork and are tracked in the
repository. The executable and window both use the ICO. The MSIX setup script
validates these assets instead of replacing them with solid-color placeholders.
Native DNS-SD is the default on Windows; an environment switch is no longer
required to discover real LAN services.

These changes do not complete the product's separate P2P file-transfer runtime
or its Windows viewer for controlling another host. The file workspace still
contains preview/intent plumbing. Windows host handshake tests, a listening
socket, and DNS-SD discovery do not replace a real Mac-viewer frame/input receipt.
On the September 8 validation host, the desktop smoke also reports that no
system audio output endpoint is available; audio acceptance remains open.

## Native validation and deployment (2026-09-08, R9)

The R9 Windows candidate builds with zero errors and zero warnings and passes
179 contract cases, 75 native protocol assertions and 32 native identity
assertions. Its native DNS-SD acceptance locates the actual Mac with the expected
device ID and fingerprint on the same discovered record. The Windows UI uses
resolved Bonjour instance names for canonical advertisements that omit `name`;
these names never grant trust. Completed snapshots no longer claim an active
scan. The discovered-device list appears ahead of expandable native diagnostics.

The unchanged Rust sources pass formatting, Clippy with all targets/features and
warnings denied, and 221 tests on Windows with the explicit
`x86_64-pc-windows-msvc` target. The product and tests use the existing native
target directory and the toolchain's `rust-lld.exe`. An earlier untargeted Clippy
attempt was blocked by Smart App Control when loading a proc-macro DLL; endpoint
protection and application-control policy were not changed.

The real Mac-to-Windows connection to R7 completes authentication and local approval,
then receives the Windows H.264 stream. It does **not** pass visible-frame or
input acceptance: the running Mac viewer's `StableRenderer` supplies compressed
Annex-B bytes without SPS/PPS-derived format metadata and reports VideoToolbox
`kVTFormatDescriptionChangeNotSupportedErr` (-12916). The existing Mac
`RemoteFrameRenderer.processH264AnnexBAccessUnit` independently decodes the
Windows native sample into a nonblank 1280×720 Metal texture. This isolates the
remaining issue to the active Mac playback path; the Mac source is unchanged in
this Windows candidate.
The handshake and desktop-runtime source files are unchanged between R7 and R9;
the R9 changes concern discovery names, completed-scan state and presentation.

The full audio-inclusive native desktop smoke remains failed because the host
has no default audio output endpoint (0x80070490). Capture, encoder output and
locally injected input observations from that smoke are individual observations,
not a replacement for Mac-origin input or complete audio acceptance. The separate
file-transfer product runtime and Windows viewer remain incomplete.

Deployment is an unpackaged local candidate under the user's
`SkyBridge-WindowsRepair-20260908/product-r9` directory. Earlier applications,
identity and trust data are preserved. This is not a signed MSIX release.
