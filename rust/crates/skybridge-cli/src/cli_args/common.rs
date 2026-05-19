use clap::Args;

#[derive(Debug, Args)]
pub(crate) struct OutputOptions {
    #[arg(long)]
    pub(crate) json: bool,
}
