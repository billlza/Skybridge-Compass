use std::io::{IsTerminal, Write};
use std::time::Instant;

use anyhow::{Context, Result};
use clap::ValueEnum;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, ValueEnum)]
pub(crate) enum ProgressMode {
    #[default]
    Auto,
    Always,
    Never,
}

/// A terminal view of observed bytes. Completion remains a separate receipt
/// result; reaching the end of the bar never creates a success notification.
pub(crate) struct TransferProgress {
    enabled: bool,
    interactive: bool,
    started: Instant,
    last: Option<(String, u64, u64)>,
}

impl TransferProgress {
    pub(crate) fn new(mode: ProgressMode, json: bool) -> Self {
        let interactive = std::io::stderr().is_terminal();
        Self {
            enabled: !json
                && (mode == ProgressMode::Always || (mode == ProgressMode::Auto && interactive)),
            interactive,
            started: Instant::now(),
            last: None,
        }
    }

    pub(crate) fn update(&mut self, stage: &str, bytes: u64, total: u64) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        let stage: String = stage.chars().filter(|c| !c.is_control()).take(80).collect();
        let current = (stage, bytes, total);
        if self.last.as_ref() == Some(&current) {
            return Ok(());
        }
        let line = render(
            &current.0,
            bytes,
            total,
            self.started.elapsed().as_secs_f64(),
        );
        let mut stderr = std::io::stderr().lock();
        if self.interactive {
            write!(stderr, "\r\x1b[2K{line}")?;
        } else {
            writeln!(stderr, "{line}")?;
        }
        stderr.flush().context("flush transfer progress")?;
        self.last = Some(current);
        Ok(())
    }

    pub(crate) fn pause(&mut self) -> Result<()> {
        if self.enabled && self.interactive && self.last.is_some() {
            writeln!(std::io::stderr().lock())?;
        }
        self.last = None;
        Ok(())
    }

    pub(crate) fn finish(&mut self) -> Result<()> {
        self.pause()?;
        self.enabled = false;
        Ok(())
    }
}

fn render(stage: &str, bytes: u64, total: u64, elapsed: f64) -> String {
    let fraction = if total == 0 {
        0.0
    } else {
        (bytes as f64 / total as f64).clamp(0.0, 1.0)
    };
    let filled = (fraction * 24.0).floor() as usize;
    let speed = if elapsed > 0.0 {
        bytes as f64 / elapsed
    } else {
        0.0
    };
    let eta = if speed > 0.0 && bytes < total {
        format!(" ETA ~{:.0}s", (total - bytes) as f64 / speed)
    } else {
        String::new()
    };
    format!(
        "[{}{}] {:>3.0}%  {bytes}/{total} B  {:.1} KiB/s{eta}  {stage}",
        "#".repeat(filled),
        "-".repeat(24 - filled),
        fraction * 100.0,
        speed / 1024.0
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_bytes_sent_still_displays_receipt_wait() {
        let line = render("waiting for receiver receipt", 100, 100, 2.0);
        assert!(line.contains("100%"));
        assert!(line.contains("waiting for receiver receipt"));
        assert!(!line.contains("completed"));
    }
    #[test]
    fn empty_file_and_zero_elapsed_do_not_invent_rate_or_success() {
        let line = render("preparing", 0, 0, 0.0);
        assert!(!line.contains("NaN"));
        assert!(!line.contains("inf"));
        assert!(line.contains("0/0 B"));
    }
}
