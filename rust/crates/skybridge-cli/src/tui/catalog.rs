use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Category {
    General,
    Network,
    Devices,
    Files,
    Desktop,
    Monitor,
    Permissions,
    Advanced,
}

impl Category {
    pub const ALL: [Self; 8] = [
        Self::General,
        Self::Network,
        Self::Devices,
        Self::Files,
        Self::Desktop,
        Self::Monitor,
        Self::Permissions,
        Self::Advanced,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Self::General => "通用",
            Self::Network => "网络",
            Self::Devices => "设备",
            Self::Files => "文件传输",
            Self::Desktop => "远程桌面",
            Self::Monitor => "系统监控",
            Self::Permissions => "权限",
            Self::Advanced => "高级",
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Network => "network",
            Self::Devices => "device",
            Self::Files => "file",
            Self::Desktop => "desktop",
            Self::Monitor => "monitor",
            Self::Permissions => "permission",
            Self::Advanced => "advanced",
        }
    }
    pub fn find(query: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|c| c.title() == query || c.key().eq_ignore_ascii_case(query))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Control {
    Toggle,
    LogLevel,
    FrameRate,
    Resolution,
    ReadOnly,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct Setting {
    pub id: &'static str,
    pub title: &'static str,
    pub category: Category,
    pub control: Control,
    pub note: &'static str,
}

pub(super) const SETTINGS: &[Setting] = &[
    Setting {
        id: "general.auto_scan_startup",
        title: "启动时自动扫描设备",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "general.notifications",
        title: "系统通知",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "general.dark_mode",
        title: "深色模式",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "general.device_details",
        title: "显示设备详情",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "general.connection_stats",
        title: "显示连接统计",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "general.compact_mode",
        title: "紧凑布局",
        category: Category::General,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "network.bonjour_discovery",
        title: "Bonjour 设备发现",
        category: Category::Network,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "network.mdns_resolution",
        title: "mDNS 名称解析",
        category: Category::Network,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.auto_connect_paired",
        title: "自动连接已配对设备",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.show_rssi",
        title: "显示设备信号强度",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.connectable_only",
        title: "仅显示可连接设备",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.hide_offline",
        title: "隐藏离线设备",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.sort_by_signal",
        title: "按信号强度排序",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "device.icons",
        title: "显示设备图标",
        category: Category::Devices,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "file.notifications",
        title: "文件传输通知",
        category: Category::Files,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "file.keep_history",
        title: "保留传输历史",
        category: Category::Files,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "file.keep_awake",
        title: "传输时保持唤醒",
        category: Category::Files,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.cpu_visible",
        title: "显示 CPU 面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.memory_visible",
        title: "显示内存面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.temperature_visible",
        title: "显示温度面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.fan_visible",
        title: "显示风扇面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.disk_visible",
        title: "显示磁盘面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.network_visible",
        title: "显示网络面板",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.trend_indicators",
        title: "显示监控趋势",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "monitor.auto_refresh",
        title: "自动刷新监控",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "advanced.realtime_weather",
        title: "实时天气",
        category: Category::Advanced,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "advanced.hardware_acceleration",
        title: "硬件加速",
        category: Category::Advanced,
        control: Control::Toggle,
        note: "保存本机应用设置；权限与协议身份使用各自的授权流程。",
    },
    Setting {
        id: "ui.top_bar_ip_location",
        title: "顶部栏显示 IP 归属地",
        category: Category::General,
        control: Control::Toggle,
        note: "控制本机顶部栏的显示。",
    },
    Setting {
        id: "ui.top_bar_network_speed",
        title: "顶部栏显示网络速度",
        category: Category::Network,
        control: Control::Toggle,
        note: "控制本机顶部栏的显示。",
    },
    Setting {
        id: "ui.top_bar_network_latency",
        title: "顶部栏显示网络延迟",
        category: Category::Network,
        control: Control::Toggle,
        note: "控制本机顶部栏的显示。",
    },
    Setting {
        id: "remote_desktop.target_fps",
        title: "远程画面帧率",
        category: Category::Desktop,
        control: Control::FrameRate,
        note: "下次启动画面采集时生效，当前会话不会重新调整。",
    },
    Setting {
        id: "remote_desktop.resolution",
        title: "远程画面分辨率",
        category: Category::Desktop,
        control: Control::Resolution,
        note: "下次启动画面采集时生效，当前会话不会重新调整。",
    },
    Setting {
        id: "ui.show_realtime_fps",
        title: "显示实时渲染帧率 FPS",
        category: Category::Monitor,
        control: Control::Toggle,
        note: "这是本机帧率显示开关；不代表读取 CPU 或内存指标。",
    },
    Setting {
        id: "logging.verbose",
        title: "详细日志",
        category: Category::Advanced,
        control: Control::Toggle,
        note: "控制本机详细日志记录。",
    },
    Setting {
        id: "logging.level",
        title: "日志级别",
        category: Category::Advanced,
        control: Control::LogLevel,
        note: "控制本机日志记录级别。",
    },
    Setting {
        id: "pqc.signature_algorithm",
        title: "协议签名算法",
        category: Category::Advanced,
        control: Control::ReadOnly,
        note: "只读；身份更换需要原生身份提交流程。加密套件请进入 /handshake。",
    },
    Setting {
        id: "pqc.prefer_xwing_hybrid",
        title: "X-Wing 策略偏好",
        category: Category::Advanced,
        control: Control::ReadOnly,
        note: "只读偏好，不代表实际会话套件。切换套件请进入 /handshake。",
    },
];

impl Setting {
    pub fn choices(self) -> Vec<(&'static str, Value)> {
        match self.control {
            Control::Toggle => vec![("开启", json!(true)), ("关闭", json!(false))],
            Control::LogLevel => ["trace", "debug", "info", "warning", "error", "critical"]
                .into_iter()
                .map(|v| (v, json!(v)))
                .collect(),
            Control::FrameRate => [("30 FPS", 30), ("60 FPS", 60), ("120 FPS", 120)]
                .into_iter()
                .map(|(t, v)| (t, json!(v)))
                .collect(),
            Control::Resolution => [
                "auto",
                "1024x768",
                "1280x720",
                "1366x768",
                "1920x1080",
                "2560x1440",
                "3840x2160",
                "5120x2880",
            ]
            .into_iter()
            .map(|v| (v, json!(v)))
            .collect(),
            Control::ReadOnly => Vec::new(),
        }
    }
    pub fn matches(self, query: &str) -> bool {
        [
            self.id,
            self.title,
            self.category.title(),
            self.category.key(),
        ]
        .iter()
        .any(|text| text.to_lowercase().contains(&query.to_lowercase()))
    }
}

/// Only the command is folded to lowercase; arguments can be case-sensitive paths.
pub(super) fn command_parts(line: &str) -> (String, &str) {
    let line = line.trim();
    let (command, argument) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
    (command.to_ascii_lowercase(), argument.trim())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn commands_preserve_case_and_spaces_in_file_paths() {
        assert_eq!(command_parts(" /USB "), ("/usb".into(), ""));
        assert_eq!(
            command_parts("/SEND /Users/A File.TXT"),
            ("/send".into(), "/Users/A File.TXT")
        );
    }
    #[test]
    fn categories_match_the_native_settings_navigation() {
        assert_eq!(
            Category::ALL.map(Category::title),
            [
                "通用",
                "网络",
                "设备",
                "文件传输",
                "远程桌面",
                "系统监控",
                "权限",
                "高级"
            ]
        );
        assert_eq!(Category::find("NETWORK"), Some(Category::Network));
    }
    #[test]
    fn identity_settings_never_offer_one_step_writes() {
        for s in SETTINGS.iter().filter(|s| s.id.starts_with("pqc.")) {
            assert!(s.choices().is_empty());
            assert_eq!(s.control, Control::ReadOnly);
        }
        assert_eq!(
            SETTINGS.iter().filter(|s| !s.choices().is_empty()).count(),
            35
        );
    }
    #[test]
    fn search_finds_human_names_and_stable_ids() {
        assert!(SETTINGS.iter().any(|s| s.matches("分辨率")));
        assert!(SETTINGS.iter().any(|s| s.matches("LOGGING.LEVEL")));
        assert!(!SETTINGS.iter().any(|s| s.matches("不存在的设置")));
    }
}
