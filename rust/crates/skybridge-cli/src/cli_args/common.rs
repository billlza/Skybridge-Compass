use clap::Args;

#[derive(Debug, Clone, Copy, Args)]
pub(crate) struct OutputOptions {
    #[arg(long)]
    pub(crate) json: bool,
}
