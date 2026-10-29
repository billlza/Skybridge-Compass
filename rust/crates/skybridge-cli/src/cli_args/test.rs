use clap::{Args, Subcommand};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct TestCommand {
    #[command(subcommand)]
    pub(crate) command: TestSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum TestSubcommand {
    Swift(SwiftTestArgs),
}

#[derive(Debug, Args)]
pub(crate) struct SwiftTestArgs {
    #[arg(long)]
    pub(crate) filter: Option<String>,
    #[arg(long)]
    pub(crate) dry_run: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
