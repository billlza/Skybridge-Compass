//! Guided terminal navigation over the existing native operator contract.
//! Menus own presentation and selection only; mutations remain in native services.
mod catalog;

use crate::handshake_commands::safe;
use anyhow::{Result, anyhow, bail};
use catalog::{Category, Control, SETTINGS, command_parts};
use serde_json::Value;
use skybridge_crossnet_client::{NearbyDevice, SettingsSnapshotResult, USBPeerChoice};
use std::io::{self, IsTerminal, Write};

#[derive(Clone, Debug)]
enum Page {
    Home,
    Settings,
    Category(Category),
    Devices,
    DevicePicker,
    Usb,
    UsbDevice(String),
    UsbPeers(String),
    Files,
    Search(String),
    Setting(usize),
    Confirm {
        index: usize,
        before: Value,
        after: Value,
    },
    FilePath,
}
impl Page {
    fn title(&self) -> String {
        match self {
            Self::Home => "首页".into(),
            Self::Settings => "设置".into(),
            Self::Category(c) => c.title().into(),
            Self::Devices => "设备".into(),
            Self::DevicePicker => "选择设备".into(),
            Self::Usb => "USB".into(),
            Self::UsbDevice(_) => "USB 设备操作".into(),
            Self::UsbPeers(_) => "选择已配对身份".into(),
            Self::Files => "文件".into(),
            Self::Search(q) => format!("查找：{}", safe(q)),
            Self::Setting(i) => SETTINGS[*i].title.into(),
            Self::Confirm { .. } => "确认修改".into(),
            Self::FilePath => "发送文件".into(),
        }
    }
}
#[derive(Clone, Debug)]
enum TargetAction {
    Connect,
    Status,
    Send(Option<String>),
    Approvals,
    AuthorizeFiles,
    RevokeFiles,
    RevokeHandshake,
}
#[derive(Clone, Debug)]
enum Action {
    Open(Page),
    Target(TargetAction),
    Pick(NearbyDevice),
    ConnectUSB(USBSelection),
    WakeUSB(String),
    LocalOnly,
    Handshake,
    RuntimeStatus,
    Capabilities,
    About,
    DesktopHelp,
    Propose {
        index: usize,
        before: Value,
        after: Value,
    },
    Commit {
        index: usize,
        before: Value,
        after: Value,
    },
    Back,
}

#[derive(Clone, Debug)]
struct USBSelection {
    udid: String,
    peer: USBPeerChoice,
}
#[derive(Clone)]
struct Item {
    label: String,
    action: Action,
}
fn item(label: impl Into<String>, action: Action) -> Item {
    Item {
        label: label.into(),
        action,
    }
}
fn target_item(label: &str, action: TargetAction) -> Item {
    item(label, Action::Target(action))
}

struct Session {
    pages: Vec<Page>,
    target: Option<NearbyDevice>,
    usb_selection: Option<USBSelection>,
    pending: Option<TargetAction>,
    exit: bool,
}
impl Session {
    fn new() -> Self {
        Self {
            pages: vec![Page::Home],
            target: None,
            usb_selection: None,
            pending: None,
            exit: false,
        }
    }
    fn page(&self) -> &Page {
        self.pages
            .last()
            .expect("navigation always retains the home page")
    }
    fn open(&mut self, page: Page) {
        self.pages.push(page);
    }
    fn back(&mut self) {
        if self.pages.len() > 1 {
            self.pages.pop();
        }
        self.pending = None;
    }
    fn jump(&mut self, page: Page) {
        self.pages.truncate(1);
        self.pending = None;
        if !matches!(page, Page::Home) {
            self.open(page);
        }
    }
    fn target_name(&self) -> String {
        self.target
            .as_ref()
            .map(|d| safe(&d.name))
            .or_else(|| {
                self.usb_selection
                    .as_ref()
                    .map(|s| format!("{}（未连接）", safe(&s.peer.name)))
            })
            .unwrap_or_else(|| "尚未选择".into())
    }
    async fn items(&self) -> Result<Vec<Item>> {
        match self.page() {
            Page::Home => Ok(vec![
                item(
                    "设置 /setting · 按分类浏览或查找功能",
                    Action::Open(Page::Settings),
                ),
                item(
                    "设备 /device · 查找、选择、连接",
                    Action::Open(Page::Devices),
                ),
                item("USB /usb · 查看线连设备并连接", Action::Open(Page::Usb)),
                item("文件 /file · 发送、审批和授权", Action::Open(Page::Files)),
                item(
                    "握手 /handshake · Q-Periapt / X-Wing / ML-KEM",
                    Action::Handshake,
                ),
            ]),
            Page::Settings => Ok(Category::ALL
                .into_iter()
                .map(|c| item(c.title(), Action::Open(Page::Category(c))))
                .collect()),
            Page::Category(category) => {
                let mut rows = category_actions(*category);
                if SETTINGS.iter().any(|s| s.category == *category) {
                    let snapshot = skybridge_crossnet_client::settings_snapshot().await?;
                    for (index, spec) in SETTINGS
                        .iter()
                        .enumerate()
                        .filter(|(_, s)| s.category == *category)
                    {
                        let value = setting_value(&snapshot, index)?;
                        rows.push(item(
                            format!(
                                "{} · {}{}",
                                spec.title,
                                value_label(value),
                                if spec.control == Control::ReadOnly {
                                    " [只读]"
                                } else {
                                    ""
                                }
                            ),
                            Action::Open(Page::Setting(index)),
                        ));
                    }
                }
                Ok(rows)
            }
            Page::Devices => Ok(device_actions()),
            Page::Files => Ok(file_actions()),
            Page::DevicePicker => {
                let devices = skybridge_crossnet_client::nearby(3).await?.devices;
                if devices.is_empty() {
                    println!("未发现 SkyBridge 设备。可检查对端应用，或回到 /usb 查看线连设备。");
                }
                let mut rows: Vec<_> = devices
                    .into_iter()
                    .map(|d| {
                        item(
                            format!(
                                "{} · {}",
                                safe(&d.name),
                                d.transport
                                    .as_deref()
                                    .map(safe)
                                    .unwrap_or_else(|| "未连接".into())
                            ),
                            Action::Pick(d),
                        )
                    })
                    .collect();
                if self.pending.is_none() {
                    rows.push(item("仅本机（清除当前目标）", Action::LocalOnly));
                }
                Ok(rows)
            }
            Page::Usb => {
                let devices = skybridge_crossnet_client::usb_devices().await?.devices;
                println!("选择物理 USB 设备；下一步选择已配对身份，无需局域网发现。");
                if devices.is_empty() {
                    println!("当前没有物理 USB 设备；插线后输入 /refresh。");
                }
                Ok(devices
                    .into_iter()
                    .map(|d| {
                        item(
                            format!("USB · {}", safe(&d.udid)),
                            Action::Open(Page::UsbDevice(d.udid)),
                        )
                    })
                    .collect())
            }
            Page::UsbDevice(udid) => {
                println!("USB：{}", safe(udid));
                Ok(vec![
                    item("连接已配对身份", Action::Open(Page::UsbPeers(udid.clone()))),
                    item(
                        "在设备上打开 SkyBridge（需要 Apple 开发工具）",
                        Action::WakeUSB(udid.clone()),
                    ),
                ])
            }
            Page::UsbPeers(udid) => {
                println!(
                    "USB：{}\n选择线另一端的已配对身份，连接时会核验指纹。",
                    safe(udid)
                );
                let peers = skybridge_crossnet_client::usb_peers().await?.peers;
                if peers.is_empty() {
                    println!("尚无可用的配对记录；新设备需要先完成一次 SkyBridge 身份核对。");
                }
                let mut rows = Vec::new();
                for peer in peers {
                    if let Some(reason) = &peer.unavailable_reason {
                        let explanation = match reason.as_str() {
                            "pairing_identity_needs_verification" => "配对身份需要重新核验",
                            _ => "配对记录不可用，请检查设备的信任设置",
                        };
                        println!("{} · 暂不可连接：{}", safe(&peer.name), explanation);
                        continue;
                    }
                    let fingerprint = peer
                        .expected_fingerprint
                        .as_deref()
                        .ok_or_else(|| anyhow!("配对记录缺少协议指纹"))?;
                    rows.push(item(
                        format!(
                            "{} · 身份 {} · 指纹 {}",
                            safe(&peer.name),
                            peer.peer_id.chars().take(8).collect::<String>(),
                            fingerprint.chars().take(12).collect::<String>()
                        ),
                        Action::ConnectUSB(USBSelection {
                            udid: udid.clone(),
                            peer,
                        }),
                    ));
                }
                Ok(rows)
            }
            Page::Search(query) => {
                let rows = search_items(query);
                if rows.is_empty() {
                    println!("没有匹配功能。试试 /setting 网络、/setting 帧率 或 /setting 授权。");
                }
                Ok(rows)
            }
            Page::Setting(index) => {
                let snapshot = skybridge_crossnet_client::settings_snapshot().await?;
                let before = setting_value(&snapshot, *index)?.clone();
                let spec = SETTINGS[*index];
                println!("本机当前值：{}\n{}", value_label(&before), spec.note);
                Ok(spec
                    .choices()
                    .into_iter()
                    .map(|(label, after)| {
                        item(
                            format!("{}{}", label, if before == after { "（当前）" } else { "" }),
                            Action::Propose {
                                index: *index,
                                before: before.clone(),
                                after,
                            },
                        )
                    })
                    .collect())
            }
            Page::Confirm {
                index,
                before,
                after,
            } => {
                println!(
                    "本机 · {}：{} → {}\n{}",
                    SETTINGS[*index].title,
                    value_label(before),
                    value_label(after),
                    SETTINGS[*index].note
                );
                Ok(vec![
                    item(
                        "保存并核对结果",
                        Action::Commit {
                            index: *index,
                            before: before.clone(),
                            after: after.clone(),
                        },
                    ),
                    item("取消", Action::Back),
                ])
            }
            Page::FilePath => {
                println!(
                    "发送到「{}」。输入文件路径（可含空格）；回车取消。",
                    self.target_name()
                );
                Ok(Vec::new())
            }
        }
    }
    async fn act(&mut self, action: Action) -> Result<()> {
        match action {
            Action::Open(page) => self.open(page),
            Action::Back => self.back(),
            Action::Pick(device) => {
                println!("已选择：{}", safe(&device.name));
                self.usb_selection = None;
                self.target = Some(device);
                self.pages.pop();
                if let Some(next) = self.pending.take() {
                    self.target_action(next).await?;
                }
            }
            Action::LocalOnly => {
                self.target = None;
                self.usb_selection = None;
                self.back();
                println!("当前仅操作本机。");
            }
            Action::Target(action) => {
                if matches!(action, TargetAction::Connect) && self.usb_selection.is_some() {
                    self.connect_selected_usb().await?;
                } else if self.target.is_none() && self.usb_selection.is_some() {
                    bail!("所选 USB 设备尚未连接；先在 /device 中连接，或用 /USB 重新选择");
                } else if self.target.is_none() {
                    println!("先选择这次操作的设备。");
                    self.pending = Some(action);
                    self.open(Page::DevicePicker);
                } else {
                    self.target_action(action).await?;
                }
            }
            Action::ConnectUSB(selection) => {
                self.usb_selection = Some(selection);
                self.target = None;
                self.connect_selected_usb().await?;
                self.jump(Page::Devices);
            }
            Action::WakeUSB(udid) => {
                println!("正在打开设备上的 SkyBridge…");
                let result = crate::usb_commands::wake(&udid).await?;
                println!(
                    "✓ SkyBridge 已激活（进程 {}）。下一步：连接已配对身份。",
                    result.process_id
                );
            }
            Action::Handshake => crate::handshake_commands::menu(self.target.as_ref()).await?,
            Action::RuntimeStatus => {
                println!("本机跨网服务状态（附近 USB 会话请查看设备状态）：");
                crate::crossnet_commands::status(crate::CrossnetStatusArgs {
                    watch: false,
                    output: crate::OutputOptions { json: false },
                })
                .await?;
            }
            Action::Capabilities => crate::crossnet_commands::preflight(false).await?,
            Action::About => println!(
                "SkyBridge {} · 设置修改作用于本机；文件审批和握手管理作用于所选设备。",
                env!("CARGO_PKG_VERSION")
            ),
            Action::DesktopHelp => println!(
                "本菜单可设置远程画面的分辨率和帧率。CLI 启动观看窗口、显示首帧和发送输入尚未接入；修改画质不代表已经建立远程桌面。"
            ),
            Action::Propose {
                index,
                before,
                after,
            } => {
                if before == after {
                    println!("已是所选值；没有写入设置。");
                } else {
                    self.open(Page::Confirm {
                        index,
                        before,
                        after,
                    });
                }
            }
            Action::Commit {
                index,
                before,
                after,
            } => {
                let snapshot = skybridge_crossnet_client::settings_snapshot().await?;
                require_unchanged(&snapshot, index, &before)?;
                let result =
                    skybridge_crossnet_client::settings_set(SETTINGS[index].id, after).await?;
                println!(
                    "✓ 已保存并读回：{} = {}",
                    SETTINGS[index].title,
                    value_label(&result.observed_value)
                );
                if result.note.as_deref() == Some("applies_at_next_capture_start") {
                    println!("下次启动画面采集时生效。");
                }
                self.back();
            }
        }
        Ok(())
    }
    async fn target_action(&mut self, action: TargetAction) -> Result<()> {
        let device = self
            .target
            .clone()
            .ok_or_else(|| anyhow!("尚未选择目标设备"))?;
        match action {
            TargetAction::Connect => {
                let connection =
                    skybridge_crossnet_client::connect_nearby(&device.device_ref).await?;
                println!(
                    "✓ {} 已认证连接 · {} · {}",
                    safe(&device.name),
                    connection
                        .transport
                        .as_deref()
                        .map(safe)
                        .unwrap_or_else(|| "传输方式未报告".into()),
                    connection
                        .negotiated_suite
                        .as_deref()
                        .map(safe)
                        .unwrap_or_else(|| "套件未报告".into())
                );
                if let Some(target) = &mut self.target {
                    target.device_ref = connection.device_ref;
                    target.authenticated = connection.authenticated;
                    target.transport = connection.transport;
                }
            }
            TargetAction::Status => {
                let result = skybridge_crossnet_client::handshake(
                    "status",
                    "local",
                    Some(&device.device_ref),
                    None,
                    false,
                )
                .await?;
                crate::handshake_commands::print_result(&result, false)?;
                if !result.success {
                    bail!("设备状态未完整读回；请查看上面的失败原因");
                }
            }
            TargetAction::Send(None) => self.open(Page::FilePath),
            TargetAction::Send(Some(path)) => {
                crate::crossnet_commands::send_file(crate::CrossnetFileSendArgs {
                    path: file_path(&path)?.into(),
                    to: device.device_ref,
                    approval: crate::FileApprovalMode::Prompt,
                    timeout_seconds: 300,
                    progress: crate::transfer_progress::ProgressMode::Auto,
                    output: crate::OutputOptions { json: false },
                })
                .await?;
            }
            TargetAction::Approvals => {
                crate::file_approval_commands::menu(&device.device_ref).await?
            }
            TargetAction::AuthorizeFiles | TargetAction::RevokeFiles => {
                crate::file_approval_commands::command(crate::CrossnetFileApprovalArgs {
                    action: if matches!(action, TargetAction::AuthorizeFiles) {
                        crate::FileApprovalAction::Authorize
                    } else {
                        crate::FileApprovalAction::Revoke
                    },
                    to: device.device_ref,
                    approval_id: None,
                    decision: None,
                    output: crate::OutputOptions { json: false },
                })
                .await?;
            }
            TargetAction::RevokeHandshake => {
                let result = skybridge_crossnet_client::handshake(
                    "revoke",
                    "local",
                    Some(&device.device_ref),
                    None,
                    false,
                )
                .await?;
                crate::handshake_commands::print_result(&result, false)?;
                if !result.success {
                    bail!("撤销未完成；请查看上面的失败原因");
                }
            }
        }
        Ok(())
    }
    async fn connect_selected_usb(&mut self) -> Result<()> {
        let selected = self
            .usb_selection
            .clone()
            .ok_or_else(|| anyhow!("尚未选择 USB 身份"))?;
        let fingerprint = selected
            .peer
            .expected_fingerprint
            .as_deref()
            .ok_or_else(|| anyhow!("配对身份需要重新验证，不能连接"))?;
        // The selection retains only a public peer ID and expected pin. Every
        // reconnect obtains a fresh authenticated reference from the native owner.
        self.target = None;
        let connection = skybridge_crossnet_client::connect_usb(
            &selected.udid,
            &selected.peer.peer_id,
            fingerprint,
        )
        .await?;
        println!(
            "✓ {} 已认证连接 · USB · {}",
            safe(&selected.peer.name),
            connection
                .negotiated_suite
                .as_deref()
                .map(safe)
                .unwrap_or_else(|| "套件未报告".into())
        );
        self.target = Some(NearbyDevice {
            device_ref: connection.device_ref,
            name: selected.peer.name,
            platform: None,
            authenticated: connection.authenticated,
            transport: connection.transport,
        });
        Ok(())
    }
    async fn command(&mut self, command: &str, arg: &str) -> Result<()> {
        if !arg.is_empty()
            && !matches!(
                command,
                "/setting" | "/settings" | "/find" | "/search" | "/file" | "/send"
            )
        {
            bail!("这个入口不接受额外参数；请输入短命令后按菜单选择");
        }
        match command {
            "/quit" | "/exit" => self.exit = true,
            "/back" => self.back(),
            "/home" | "/help" => self.jump(Page::Home),
            "/refresh" => {}
            "/setting" | "/settings" | "/find" | "/search" => {
                self.jump(Page::Settings);
                if !arg.is_empty() {
                    if let Some(category) = Category::find(arg) {
                        self.open(Page::Category(category));
                    } else {
                        self.open(Page::Search(arg.into()));
                    }
                }
            }
            "/device" => self.jump(Page::Devices),
            "/devices" => self.jump(Page::DevicePicker),
            "/usb" => self.jump(Page::Usb),
            "/file" if arg.is_empty() => self.jump(Page::Files),
            "/file" | "/send" => {
                self.act(Action::Target(TargetAction::Send(
                    (!arg.is_empty()).then(|| arg.to_owned()),
                )))
                .await?
            }
            "/connect" => self.act(Action::Target(TargetAction::Connect)).await?,
            "/status" if self.target.is_none() => {
                let result =
                    skybridge_crossnet_client::handshake("status", "local", None, None, false)
                        .await?;
                crate::handshake_commands::print_result(&result, false)?;
            }
            "/status" => self.act(Action::Target(TargetAction::Status)).await?,
            "/handshake" => self.act(Action::Handshake).await?,
            "/approvals" => self.act(Action::Target(TargetAction::Approvals)).await?,
            "/revoke" => {
                self.act(Action::Target(TargetAction::RevokeHandshake))
                    .await?
            }
            "/network" | "/desktop" | "/monitor" | "/permission" | "/permissions" | "/advanced" => {
                let key = if command == "/permissions" {
                    "permission"
                } else {
                    &command[1..]
                };
                self.jump(Page::Settings);
                self.open(Page::Category(
                    Category::find(key).ok_or_else(|| anyhow!("未知分类"))?,
                ));
            }
            _ => bail!("未知命令；用 /help 查看入口，或 /setting 关键词 查找功能"),
        }
        Ok(())
    }
}

fn device_actions() -> Vec<Item> {
    vec![
        item("查找并选择附近设备", Action::Open(Page::DevicePicker)),
        target_item("连接所选设备（USB 优先）", TargetAction::Connect),
        target_item("查看连接与握手状态", TargetAction::Status),
        item("选择 USB 线连接", Action::Open(Page::Usb)),
    ]
}
fn file_actions() -> Vec<Item> {
    vec![
        target_item("发送文件", TargetAction::Send(None)),
        target_item("查看并处理文件审批", TargetAction::Approvals),
        target_item("申请 CLI 文件审批授权", TargetAction::AuthorizeFiles),
        target_item("撤销 CLI 文件审批授权", TargetAction::RevokeFiles),
    ]
}
fn category_actions(category: Category) -> Vec<Item> {
    match category {
        Category::General => vec![item("版本与操作范围", Action::About)],
        Category::Network => vec![
            item("选择握手套件", Action::Handshake),
            target_item("查看设备连接状态", TargetAction::Status),
            item("查看本机跨网服务状态", Action::RuntimeStatus),
        ],
        Category::Devices => device_actions(),
        Category::Files => file_actions(),
        Category::Desktop => vec![item("远程桌面功能范围", Action::DesktopHelp)],
        Category::Monitor => vec![item("本机服务与连接状态", Action::RuntimeStatus)],
        Category::Permissions => vec![
            target_item("查看并处理文件审批", TargetAction::Approvals),
            target_item("申请文件审批授权", TargetAction::AuthorizeFiles),
            target_item("撤销文件审批授权", TargetAction::RevokeFiles),
            target_item("查看握手管理状态", TargetAction::Status),
            target_item("撤销握手管理授权", TargetAction::RevokeHandshake),
        ],
        Category::Advanced => vec![item("检查本机 CLI 服务能力", Action::Capabilities)],
    }
}
fn search_items(query: &str) -> Vec<Item> {
    let query = query.to_lowercase();
    let mut rows = Vec::new();
    for category in Category::ALL {
        if category.title().contains(&query) || category.key().contains(&query) {
            rows.push(item(
                format!("分类 · {}", category.title()),
                Action::Open(Page::Category(category)),
            ));
        }
        for mut entry in category_actions(category)
            .into_iter()
            .filter(|r| r.label.to_lowercase().contains(&query))
        {
            entry.label = format!("{} › {}", category.title(), entry.label);
            rows.push(entry);
        }
    }
    for (index, spec) in SETTINGS
        .iter()
        .enumerate()
        .filter(|(_, s)| s.matches(&query))
    {
        rows.push(item(
            format!("{} › {}", spec.category.title(), spec.title),
            Action::Open(Page::Setting(index)),
        ));
    }
    rows
}
fn value_label(value: &Value) -> String {
    match value {
        Value::Bool(true) => "开启".into(),
        Value::Bool(false) => "关闭".into(),
        Value::String(s) if s == "auto" => "自动".into(),
        Value::String(s) => safe(s),
        v => safe(&v.to_string()),
    }
}
fn setting_value(snapshot: &SettingsSnapshotResult, index: usize) -> Result<&Value> {
    let spec = SETTINGS[index];
    snapshot
        .settings
        .iter()
        .find(|s| s.id == spec.id)
        .map(|s| &s.value)
        .ok_or_else(|| anyhow!("当前应用未提供「{}」，无法读取或修改", spec.title))
}
fn require_unchanged(
    snapshot: &SettingsSnapshotResult,
    index: usize,
    before: &Value,
) -> Result<()> {
    if setting_value(snapshot, index)? != before {
        bail!("设置已被其他操作改变；请返回重新选择，未写入旧值");
    }
    Ok(())
}
fn file_path(input: &str) -> Result<String> {
    let path = input.trim();
    let path = path
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .or_else(|| path.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
        .unwrap_or(path);
    if path.is_empty() {
        bail!("文件路径不能为空");
    }
    Ok(path.to_owned())
}
fn read_line(prompt: &str) -> Result<Option<String>> {
    print!("{prompt}");
    io::stdout().flush()?;
    let mut line = String::new();
    if io::stdin().read_line(&mut line)? == 0 {
        return Ok(None);
    }
    Ok(Some(line.trim().to_owned()))
}
fn is_navigation(command: &str) -> bool {
    matches!(
        command,
        "/back"
            | "/home"
            | "/help"
            | "/quit"
            | "/exit"
            | "/setting"
            | "/settings"
            | "/device"
            | "/devices"
            | "/usb"
            | "/file"
            | "/refresh"
            | "/find"
            | "/search"
            | "/send"
            | "/connect"
            | "/status"
            | "/handshake"
            | "/approvals"
            | "/revoke"
            | "/network"
            | "/desktop"
            | "/monitor"
            | "/permission"
            | "/permissions"
            | "/advanced"
    )
}

pub(crate) async fn run() -> Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        bail!("tui requires an interactive terminal; use crossnet ... --json for scripts");
    }
    println!(
        "SkyBridge {} · /setting /device /usb /file /handshake",
        env!("CARGO_PKG_VERSION")
    );
    println!(
        "输入编号选择；/back 或 0 返回；/home 回首页；/quit 退出。/setting 关键词 可查找功能。"
    );
    let mut session = Session::new();
    while !session.exit {
        println!(
            "\n{}\n本机：Mac · 所选设备：{}",
            session
                .pages
                .iter()
                .map(Page::title)
                .collect::<Vec<_>>()
                .join(" › "),
            session.target_name()
        );
        if matches!(session.page(), Page::Settings) {
            println!("以下分类列出已接入 CLI 的设置与操作；本机设置不会改动对端。");
        }
        let rows = match session.items().await {
            Ok(items) => {
                for (i, row) in items.iter().enumerate() {
                    println!("{}. {}", i + 1, row.label);
                }
                Some(items)
            }
            Err(error) => {
                eprintln!(
                    "读取失败：{}；可用 /refresh 重读或 /back 返回。",
                    safe(&format!("{error:#}"))
                );
                None
            }
        };
        let Some(line) = read_line(if matches!(session.page(), Page::FilePath) {
            "文件路径 › "
        } else {
            "skybridge › "
        })?
        else {
            break;
        };
        let (command, argument) = command_parts(&line);
        let result = if matches!(session.page(), Page::FilePath)
            && !is_navigation(&command)
            && line != "0"
        {
            if line.is_empty() {
                session.back();
                Ok(())
            } else {
                session.back();
                session
                    .act(Action::Target(TargetAction::Send(Some(line))))
                    .await
            }
        } else if line == "0" || line.is_empty() {
            session.back();
            Ok(())
        } else if line.starts_with('/') {
            session.command(&command, argument).await
        } else {
            match line
                .parse::<usize>()
                .ok()
                .and_then(|n| n.checked_sub(1))
                .and_then(|n| rows.as_ref().and_then(|r| r.get(n)))
            {
                Some(row) => session.act(row.action.clone()).await,
                None => Err(anyhow!("请选择当前列表中的编号，或输入 /help")),
            }
        };
        if let Err(error) = result {
            eprintln!("操作未完成：{}", safe(&format!("{error:#}")));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn back_cancels_deferred_device_operation_and_keeps_home() {
        let mut s = Session::new();
        s.open(Page::Files);
        s.pending = Some(TargetAction::Send(None));
        s.open(Page::DevicePicker);
        s.back();
        assert!(s.pending.is_none());
        assert!(matches!(s.page(), Page::Files));
        s.back();
        s.back();
        assert_eq!(s.pages.len(), 1);
    }
    #[test]
    fn jumping_does_not_execute_deferred_operations() {
        let mut s = Session::new();
        s.pending = Some(TargetAction::RevokeFiles);
        s.open(Page::DevicePicker);
        s.jump(Page::Settings);
        assert!(s.pending.is_none());
        assert!(matches!(s.page(), Page::Settings));
    }
    #[tokio::test]
    async fn unexpected_arguments_do_not_trigger_a_command() {
        let mut s = Session::new();
        assert!(s.command("/quit", "unexpected").await.is_err());
        assert!(!s.exit);
        assert!(s.command("/revoke", "unexpected").await.is_err());
        assert!(s.pending.is_none());
    }
    #[test]
    fn sending_quoted_paths_does_not_change_case_or_execute_shell_text() {
        assert_eq!(
            file_path("\"/tmp/My File.TXT\"").unwrap(),
            "/tmp/My File.TXT"
        );
        assert_eq!(
            file_path("/tmp/$(touch nope)").unwrap(),
            "/tmp/$(touch nope)"
        );
        assert!(file_path("\"\"").is_err());
    }
    #[test]
    fn changed_or_missing_current_setting_blocks_confirmation() {
        let mut snapshot = SettingsSnapshotResult {
            runtime_target: "mac_app_runtime".into(),
            control_effect: "read_only".into(),
            settings: vec![],
        };
        assert!(require_unchanged(&snapshot, 0, &Value::Bool(false)).is_err());
        snapshot
            .settings
            .push(skybridge_crossnet_client::SettingSnapshot {
                id: SETTINGS[0].id.into(),
                value_type: "bool".into(),
                value: Value::Bool(true),
                mutable: false,
                note: None,
            });
        assert!(require_unchanged(&snapshot, 0, &Value::Bool(false)).is_err());
        assert!(require_unchanged(&snapshot, 0, &Value::Bool(true)).is_ok());
    }
    #[tokio::test]
    async fn rejected_usb_selection_cannot_reuse_the_previous_target_or_send_files() {
        let mut session = Session::new();
        session.target = Some(NearbyDevice {
            device_ref: "00000000-0000-0000-0000-000000000001".into(),
            name: "Previous peer".into(),
            platform: None,
            authenticated: true,
            transport: Some("tcp".into()),
        });
        let selection = USBSelection {
            // Validation must fail before any socket or physical device is used.
            udid: "invalid cable identifier".into(),
            peer: USBPeerChoice {
                peer_id: "00000000-0000-0000-0000-000000000002".into(),
                name: "Selected USB peer".into(),
                expected_fingerprint: Some("a".repeat(64)),
                unavailable_reason: None,
            },
        };
        assert!(session.act(Action::ConnectUSB(selection)).await.is_err());
        assert!(session.target.is_none());
        assert_eq!(
            session.usb_selection.as_ref().unwrap().peer.name,
            "Selected USB peer"
        );
        let error = session
            .act(Action::Target(TargetAction::Send(Some("unused".into()))))
            .await
            .expect_err("a failed USB connection must not send to an earlier peer");
        assert!(error.to_string().contains("尚未连接"));
        assert!(session.pending.is_none());
        assert!(!matches!(session.page(), Page::DevicePicker));
        assert!(
            session
                .act(Action::Target(TargetAction::Connect))
                .await
                .is_err()
        );
        assert!(session.target.is_none());
    }

    #[test]
    fn scripted_usb_device_selection_requires_target_and_preserves_json_mode() {
        use clap::Parser;
        let prefix = [
            "skybridge",
            "crossnet",
            "usb",
            "connect-device",
            "00008140-000E788401C0801C",
        ];
        assert!(crate::Cli::try_parse_from(prefix).is_err());
        let args =
            prefix
                .into_iter()
                .chain(["--to", "00000000-0000-0000-0000-000000000001", "--json"]);
        assert!(
            crate::Cli::try_parse_from(args)
                .unwrap()
                .json_output_requested()
        );
    }
}
