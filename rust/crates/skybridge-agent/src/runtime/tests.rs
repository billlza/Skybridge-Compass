use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use skybridge_core::{ManagedSessionControl, RuntimeSessionRole, RuntimeSessionSource};
use tokio_util::sync::CancellationToken;

use super::{
    AgentPaths, ManagedSessionWorker, reconcile_managed_sessions_with_spawner, resolve_paths,
    shutdown_managed_session_workers,
};

fn test_paths(name: &str) -> AgentPaths {
    resolve_paths(Some(std::env::temp_dir().join(format!(
        "skybridge-agent-runtime-{name}-{}",
        uuid::Uuid::now_v7()
    ))))
    .expect("temporary paths should resolve")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reconcile_respawns_finished_worker_for_active_control() {
    let paths = test_paths("reconcile-respawn");
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-1",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "session-token",
            None,
        ),
    )
    .await
    .expect("managed session control should persist");

    let finished_cancel = CancellationToken::new();
    let finished_handle = tokio::spawn(async {});
    tokio::task::yield_now().await;

    let mut workers = BTreeMap::from([(
        "session-1".to_owned(),
        ManagedSessionWorker::new(finished_cancel, finished_handle),
    )]);
    let spawn_count = Arc::new(AtomicUsize::new(0));
    let root_cancel = CancellationToken::new();

    reconcile_managed_sessions_with_spawner(&paths, &root_cancel, &mut workers, {
        let spawn_count = Arc::clone(&spawn_count);
        move |_paths, _control, cancel| {
            spawn_count.fetch_add(1, Ordering::SeqCst);
            let worker_cancel = cancel.clone();
            let handle = tokio::spawn(async move {
                worker_cancel.cancelled().await;
            });
            ManagedSessionWorker::new(cancel, handle)
        }
    })
    .await
    .expect("reconcile should respawn finished worker");

    assert_eq!(spawn_count.load(Ordering::SeqCst), 1);
    assert_eq!(workers.len(), 1);
    assert!(workers.contains_key("session-1"));
    assert!(!workers["session-1"].is_finished());

    shutdown_managed_session_workers(&mut workers).await;
    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}
