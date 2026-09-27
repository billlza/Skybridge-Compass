use anyhow::{Result, bail};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub(crate) struct USBWakeResult {
    pub runtime_target: &'static str,
    pub udid: String,
    pub app_identifier: &'static str,
    pub process_id: u64,
    pub activated: bool,
    pub authenticated_connection: bool,
}

#[cfg(any(target_os = "macos", test))]
const APP_IDENTIFIER: &str = "com.skybridge.compass.ios";

#[cfg(any(target_os = "macos", test))]
fn parse_wake_report(report: &serde_json::Value, udid: &str) -> Result<USBWakeResult> {
    use anyhow::Context;
    let arguments = report["info"]["arguments"]
        .as_array()
        .context("Apple device launch report omitted its target; activation is unconfirmed")?;
    let requested_target = arguments
        .windows(2)
        .any(|pair| pair[0].as_str() == Some("--device") && pair[1].as_str() == Some(udid));
    let options = &report["result"]["launchOptions"];
    let pid = report["result"]["process"]["processIdentifier"]
        .as_u64()
        .filter(|pid| *pid > 0);
    if report["info"]["commandType"] != "devicectl.device.process.launch"
        || report["info"]["outcome"] != "success"
        || !requested_target
        || arguments.last().and_then(|value| value.as_str()) != Some(APP_IDENTIFIER)
        || options["activatedWhenStarted"] != true
        || options["startStopped"] != false
        || options["terminateExistingInstances"] != false
        || !options["arguments"].as_array().is_some_and(Vec::is_empty)
        || pid.is_none()
    {
        bail!(
            "Apple device launch did not confirm a normal activation of the selected app; outcome unconfirmed"
        );
    }
    Ok(USBWakeResult {
        runtime_target: "apple_developer_tools",
        udid: udid.into(),
        app_identifier: APP_IDENTIFIER,
        process_id: pid.context("Apple launch report omitted the process identifier")?,
        activated: true,
        authenticated_connection: false,
    })
}

#[cfg(target_os = "macos")]
async fn devicectl(arguments: &[&str], seconds: u64) -> Result<std::process::Output> {
    use anyhow::Context;
    let mut command = tokio::process::Command::new("/usr/bin/xcrun");
    command
        .arg("devicectl")
        .args(arguments)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    // Normal activation must not inherit test/debug overrides for the device app.
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("DEVICECTL_CHILD_") {
            command.env_remove(key);
        }
    }
    tokio::time::timeout(std::time::Duration::from_secs(seconds), command.output())
        .await
        .context("Apple device command timed out; outcome unconfirmed, no automatic retry")?
        .context("Apple device tools could not run; check the selected Xcode installation")
}

#[cfg(target_os = "macos")]
pub(crate) async fn wake(udid: &str) -> Result<USBWakeResult> {
    use anyhow::Context;
    let inventory = skybridge_crossnet_client::usb_devices().await?;
    if !inventory.devices.iter().any(|device| device.udid == udid) {
        bail!("所选设备当前没有物理 USB 连接；请接线后重试");
    }
    let help = devicectl(&["device", "process", "launch", "--help"], 10).await?;
    let help_text =
        std::str::from_utf8(&help.stdout).context("Apple device tool help is not valid UTF-8")?;
    // Older tools interpret '-' as a file name. Fail before launching instead
    // of risking a write to the caller's working directory or parsing prose.
    if !help.status.success() || !help_text.contains("Pass '-' (or '/dev/stdout' / '/dev/fd/1')") {
        bail!(
            "此 Xcode 的设备工具未声明结构化标准输出支持；请更新开发工具或在设备上打开 SkyBridge"
        );
    }
    let output = devicectl(
        &[
            "device",
            "process",
            "launch",
            "--device",
            udid,
            "--timeout",
            "20",
            "--quiet",
            "--json-output",
            "-",
            APP_IDENTIFIER,
        ],
        30,
    )
    .await?;
    if !output.status.success() {
        bail!(
            "唤醒 SkyBridge 失败，请确认设备已解锁并信任此 Mac：{}",
            crate::handshake_commands::safe(&String::from_utf8_lossy(&output.stderr))
        );
    }
    if output.stdout.len() > 1024 * 1024 {
        bail!("Apple launch report exceeded its size limit; outcome unconfirmed");
    }
    let report = serde_json::from_slice(&output.stdout)
        .context("Apple launch result is not JSON; activation unconfirmed")?;
    parse_wake_report(&report, udid)
}

#[cfg(not(target_os = "macos"))]
pub(crate) async fn wake(_udid: &str) -> Result<USBWakeResult> {
    bail!("USB app activation requires macOS with Apple developer tools")
}

pub(crate) async fn command(args: crate::CrossnetUSBWakeArgs) -> Result<()> {
    let result = wake(&args.udid).await?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&result)?);
    } else {
        println!(
            "✓ SkyBridge 已激活（进程 {}）。下一步：连接已配对身份。",
            result.process_id
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn report() -> serde_json::Value {
        json!({"info":{"commandType":"devicectl.device.process.launch", "outcome":"success",
            "arguments":["devicectl","device","process","launch","--device","test-device",APP_IDENTIFIER]},
            "result":{"launchOptions":{"activatedWhenStarted":true,"startStopped":false,
                "terminateExistingInstances":false,"arguments":[]},"process":{"processIdentifier":42}}})
    }
    #[test]
    fn launch_proof_is_not_an_authenticated_connection() {
        let result = parse_wake_report(&report(), "test-device").unwrap();
        assert_eq!(result.process_id, 42);
        assert!(result.activated);
        assert!(!result.authenticated_connection);
        assert!(parse_wake_report(&report(), "another-device").is_err());
    }
    #[test]
    fn debugger_termination_and_missing_pid_are_not_normal_activation() {
        for key in ["startStopped", "terminateExistingInstances"] {
            let mut value = report();
            value["result"]["launchOptions"][key] = json!(true);
            assert!(parse_wake_report(&value, "test-device").is_err());
        }
        let mut value = report();
        value["result"]["process"]["processIdentifier"] = json!(0);
        assert!(parse_wake_report(&value, "test-device").is_err());
        let mut value = report();
        value["info"]["outcome"] = json!("failed");
        assert!(parse_wake_report(&value, "test-device").is_err());
    }
}
