use std::path::Path;
use std::process::Command;
use std::time::Instant;

use anyhow::{Result, bail};
use serde::Serialize;

use crate::SmokeSuiteProfile;
use crate::cli_text::{shell_quote, tail_lossy};

use super::plan::SmokeSuiteStepSpec;

#[derive(Debug, Serialize)]
struct SmokeSuiteEnvJson {
    name: String,
    value: String,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteStepJson {
    name: String,
    description: String,
    command: Vec<String>,
    env: Vec<SmokeSuiteEnvJson>,
    cwd: String,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteOutcomeJson {
    name: String,
    description: String,
    command: Vec<String>,
    env: Vec<SmokeSuiteEnvJson>,
    cwd: String,
    success: bool,
    exit_code: Option<i32>,
    duration_ms: u128,
    stdout_tail: Option<String>,
    stderr_tail: Option<String>,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteReportJson {
    schema_version: u8,
    profile: SmokeSuiteProfile,
    dry_run: bool,
    root: String,
    steps: Vec<SmokeSuiteStepJson>,
    outcomes: Vec<SmokeSuiteOutcomeJson>,
}

pub(super) fn run_smoke_suite_plan(
    root: &Path,
    profile: SmokeSuiteProfile,
    dry_run: bool,
    as_json: bool,
    steps: Vec<SmokeSuiteStepSpec>,
) -> Result<()> {
    if dry_run {
        let report = SmokeSuiteReportJson {
            schema_version: 1,
            profile,
            dry_run,
            root: root.display().to_string(),
            steps: steps.iter().map(step_to_json).collect(),
            outcomes: vec![],
        };
        if as_json {
            println!("{}", serde_json::to_string_pretty(&report)?);
        } else {
            print_smoke_suite_plan_text(&report);
        }
        return Ok(());
    }

    let mut outcomes = Vec::new();
    for step in &steps {
        if !as_json {
            println!("==> {}: {}", step.name, step.description);
            println!("    {}", format_smoke_step_command(step));
        }

        let started = Instant::now();
        let mut command = Command::new(&step.program);
        command.args(&step.args).current_dir(&step.cwd);
        for (name, value) in &step.env {
            command.env(name, value);
        }

        let outcome = if as_json {
            let output = command.output()?;
            SmokeSuiteOutcomeJson {
                name: step.name.to_owned(),
                description: step.description.to_owned(),
                command: step.command_vector(),
                env: step
                    .env
                    .iter()
                    .map(|(name, value)| SmokeSuiteEnvJson {
                        name: name.clone(),
                        value: value.clone(),
                    })
                    .collect(),
                cwd: step.cwd.display().to_string(),
                success: output.status.success(),
                exit_code: output.status.code(),
                duration_ms: started.elapsed().as_millis(),
                stdout_tail: Some(tail_lossy(&output.stdout, 8_000)),
                stderr_tail: Some(tail_lossy(&output.stderr, 8_000)),
            }
        } else {
            let status = command.status()?;
            SmokeSuiteOutcomeJson {
                name: step.name.to_owned(),
                description: step.description.to_owned(),
                command: step.command_vector(),
                env: step
                    .env
                    .iter()
                    .map(|(name, value)| SmokeSuiteEnvJson {
                        name: name.clone(),
                        value: value.clone(),
                    })
                    .collect(),
                cwd: step.cwd.display().to_string(),
                success: status.success(),
                exit_code: status.code(),
                duration_ms: started.elapsed().as_millis(),
                stdout_tail: None,
                stderr_tail: None,
            }
        };

        let failed_name = if outcome.success {
            None
        } else {
            Some(outcome.name.clone())
        };
        outcomes.push(outcome);
        if let Some(failed_name) = failed_name {
            let report = SmokeSuiteReportJson {
                schema_version: 1,
                profile,
                dry_run: false,
                root: root.display().to_string(),
                steps: steps.iter().map(step_to_json).collect(),
                outcomes,
            };
            if as_json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            bail!("smoke suite step `{failed_name}` failed");
        }
    }

    let report = SmokeSuiteReportJson {
        schema_version: 1,
        profile,
        dry_run: false,
        root: root.display().to_string(),
        steps: steps.iter().map(step_to_json).collect(),
        outcomes,
    };
    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("smoke suite passed: {} step(s)", report.outcomes.len());
    }
    Ok(())
}

fn step_to_json(step: &SmokeSuiteStepSpec) -> SmokeSuiteStepJson {
    SmokeSuiteStepJson {
        name: step.name.to_owned(),
        description: step.description.to_owned(),
        command: step.command_vector(),
        env: step
            .env
            .iter()
            .map(|(name, value)| SmokeSuiteEnvJson {
                name: name.clone(),
                value: value.clone(),
            })
            .collect(),
        cwd: step.cwd.display().to_string(),
    }
}

fn print_smoke_suite_plan_text(report: &SmokeSuiteReportJson) {
    println!("smoke suite plan: {:?}", report.profile);
    println!("root: {}", report.root);
    for step in &report.steps {
        let env = if step.env.is_empty() {
            String::new()
        } else {
            let rendered = step
                .env
                .iter()
                .map(|entry| format!("{}={}", entry.name, shell_quote(&entry.value)))
                .collect::<Vec<_>>()
                .join(" ");
            format!("{rendered} ")
        };
        let command = step
            .command
            .iter()
            .map(|part| shell_quote(part))
            .collect::<Vec<_>>()
            .join(" ");
        println!("  - {}: {}", step.name, step.description);
        println!("    cwd: {}", step.cwd);
        println!("    cmd: {env}{command}");
    }
}

fn format_smoke_step_command(step: &SmokeSuiteStepSpec) -> String {
    let env = if step.env.is_empty() {
        String::new()
    } else {
        let rendered = step
            .env
            .iter()
            .map(|(name, value)| format!("{name}={}", shell_quote(value)))
            .collect::<Vec<_>>()
            .join(" ");
        format!("{rendered} ")
    };
    let command = step
        .command_vector()
        .iter()
        .map(|part| shell_quote(part))
        .collect::<Vec<_>>()
        .join(" ");
    format!("cwd={} {env}{command}", step.cwd.display())
}
