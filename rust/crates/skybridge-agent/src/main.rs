use anyhow::Result;
use skybridge_agent::{AgentRuntimeOptions, run_agent};

#[tokio::main]
async fn main() -> Result<()> {
    run_agent(AgentRuntimeOptions::default()).await
}
