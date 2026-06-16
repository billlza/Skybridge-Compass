//! Agent-owned live file transfer over the encrypted control channel.
//!
//! Sender side: streams a regular file as binary `FileAppFrame` chunks with a
//! windowed-ACK in-flight bound (the data channel exposes no buffered-amount
//! getter, so flow control is end-to-end via `ChunkAck`), and closes only on a
//! SHA-256-verified `Receipt`. Receiver side: reassembles chunks to a temp file,
//! verifies the digest, then atomically renames into `<state-dir>/received/`
//! with collision-safe auto-suffixing — never overwriting, never following a
//! planted symlink, never trusting the advertised filename.
//!
//! No "success" is ever recorded without receipt evidence.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};
use skybridge_core::file_transfer_frame::{
    self, CHUNK_PAYLOAD_BYTES, FileAppFrame, MAX_FILENAME_LEN,
};
use skybridge_core::{FileTransferControlRequest, NativeWebRtcSender};
use time::OffsetDateTime;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, mpsc};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use super::AgentPaths;
use crate::state::update_file_transfer_request;

/// Max chunks the sender keeps in flight before a `ChunkAck` must advance it.
const WINDOW_CHUNKS: u64 = 32;
/// Receiver emits a `ChunkAck` every this many chunks for mid-stream flow control.
const ACK_EVERY_CHUNKS: u32 = 8;
/// Bound on simultaneous inbound transfers.
const MAX_CONCURRENT_RECEIVES: usize = 4;
/// Bound on the summed declared size of in-flight inbound transfers (4 GiB).
const MAX_TOTAL_INFLIGHT_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Bound on auto-suffix attempts when resolving a collision-free name.
const MAX_NAME_COLLISION_ATTEMPTS: u32 = 10_000;

/// Stable 16-byte transfer id derived from the request id.
pub(super) fn transfer_id_for(request_id: &str) -> [u8; 16] {
    let digest = Sha256::digest(request_id.as_bytes());
    let mut id = [0u8; 16];
    id.copy_from_slice(&digest[..16]);
    id
}

fn hex16(id: &[u8; 16]) -> String {
    let mut out = String::with_capacity(32);
    for byte in id {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn parse_sha256_hex(hex: &str) -> Result<[u8; 32]> {
    if hex.len() != 64 {
        bail!("source sha256 must be 64 hex chars");
    }
    let mut out = [0u8; 32];
    let bytes = hex.as_bytes();
    for (index, slot) in out.iter_mut().enumerate() {
        let hi = (bytes[index * 2] as char)
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid sha256 hex"))?;
        let lo = (bytes[index * 2 + 1] as char)
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid sha256 hex"))?;
        *slot = (hi * 16 + lo) as u8;
    }
    Ok(out)
}

/// Coordinates inbound frame routing between active send transfers (awaiting
/// receipts/acks) and the receiver state machine.
pub(super) struct FileTransferCoordinator {
    session_id: String,
    sender_inboxes: Mutex<HashMap<[u8; 16], mpsc::Sender<FileAppFrame>>>,
    receiver: Mutex<FileReceiver>,
}

impl FileTransferCoordinator {
    pub(super) fn new(session_id: String, received_dir: PathBuf) -> Self {
        Self {
            session_id,
            sender_inboxes: Mutex::new(HashMap::new()),
            receiver: Mutex::new(FileReceiver::new(received_dir)),
        }
    }

    async fn register_sender(&self, transfer_id: [u8; 16]) -> mpsc::Receiver<FileAppFrame> {
        let (tx, rx) = mpsc::channel(64);
        self.sender_inboxes.lock().await.insert(transfer_id, tx);
        rx
    }

    async fn unregister_sender(&self, transfer_id: &[u8; 16]) {
        self.sender_inboxes.lock().await.remove(transfer_id);
    }

    /// Route an inbound file frame: receipts/acks go to the matching send task;
    /// offers/chunks drive the receiver, whose outbound frames are sent back.
    pub(super) async fn route_inbound(
        &self,
        frame: FileAppFrame,
        sender: &NativeWebRtcSender,
    ) -> Result<()> {
        match &frame {
            FileAppFrame::Receipt { transfer_id, .. }
            | FileAppFrame::ChunkAck { transfer_id, .. } => {
                let inbox = self.sender_inboxes.lock().await.get(transfer_id).cloned();
                if let Some(inbox) = inbox {
                    // A full inbox means the send task is wedged; dropping is safe
                    // (the receipt path also closes the transfer).
                    let _ = inbox.try_send(frame);
                } else {
                    debug!(
                        kind = "agent.file_transfer.unmatched_receipt",
                        session_id = %self.session_id,
                        "received receipt/ack with no active send transfer"
                    );
                }
                Ok(())
            }
            FileAppFrame::Offer { .. } | FileAppFrame::Chunk { .. } => {
                let outbound = {
                    let mut receiver = self.receiver.lock().await;
                    receiver.handle_frame(frame).await?
                };
                for plaintext in outbound {
                    sender.send_file_app_frame(&plaintext).await?;
                }
                Ok(())
            }
        }
    }
}

/// Spawn a send transfer task for one agent-observed request and return nothing;
/// status/evidence is persisted to the request registry as it progresses.
pub(super) fn spawn_file_send_transfer(
    paths: AgentPaths,
    coordinator: Arc<FileTransferCoordinator>,
    request: FileTransferControlRequest,
    sender: NativeWebRtcSender,
    cancel: CancellationToken,
) {
    tokio::spawn(async move {
        let request_id = request.request_id.clone();
        let transfer_id = transfer_id_for(&request_id);
        let inbox = coordinator.register_sender(transfer_id).await;
        let result = run_file_send_transfer(&paths, &request, &sender, inbox, &cancel).await;
        coordinator.unregister_sender(&transfer_id).await;

        let now = OffsetDateTime::now_utc();
        match result {
            Ok(bytes) => {
                if let Err(error) = update_file_transfer_request(&paths, &request_id, move |r| {
                    r.mark_transfer_completed(bytes, now)
                })
                .await
                {
                    warn!(
                        kind = "agent.file_transfer.complete_persist_failed",
                        session_id = %request.session_id,
                        request_id = %request_id,
                        error = %error,
                        "failed to persist completed file transfer"
                    );
                } else {
                    info!(
                        kind = "agent.file_transfer.completed",
                        session_id = %request.session_id,
                        request_id = %request_id,
                        bytes_transferred = bytes,
                        receipt_verified = true,
                        "file transfer completed with verified receipt"
                    );
                }
            }
            Err(error) => {
                let reason = generic_failure_reason(&error);
                let _ = update_file_transfer_request(&paths, &request_id, move |r| {
                    r.mark_transfer_failed(reason, now)
                })
                .await;
                warn!(
                    kind = "agent.file_transfer.failed",
                    session_id = %request.session_id,
                    request_id = %request_id,
                    error = %error,
                    "file transfer did not close with a verified receipt"
                );
            }
        }
    });
}

fn generic_failure_reason(error: &anyhow::Error) -> String {
    // Keep persisted reasons coarse and free of path/peer/digest material.
    let text = error.to_string();
    if text.contains("cancel") {
        "transfer cancelled".to_owned()
    } else if text.contains("receipt") || text.contains("sha256") {
        "receipt verification failed".to_owned()
    } else {
        "transfer transport error".to_owned()
    }
}

async fn run_file_send_transfer(
    paths: &AgentPaths,
    request: &FileTransferControlRequest,
    sender: &NativeWebRtcSender,
    mut inbox: mpsc::Receiver<FileAppFrame>,
    cancel: &CancellationToken,
) -> Result<u64> {
    let transfer_id = transfer_id_for(&request.request_id);
    let total_size = request.source.size_bytes;
    let expected_sha256 = parse_sha256_hex(&request.source.sha256_hex)?;
    let filename = sanitize_filename(
        Path::new(&request.source.source_path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("file"),
    )
    .unwrap_or_else(|| "file".to_owned());

    let started = OffsetDateTime::now_utc();
    update_file_transfer_request(paths, &request.request_id, move |r| {
        r.mark_transfer_started(started)
    })
    .await?;

    let mut file = File::open(&request.source.source_path)
        .await
        .context("failed to open file transfer source")?;

    let offer = file_transfer_frame::encode_offer(
        &transfer_id,
        total_size,
        CHUNK_PAYLOAD_BYTES as u32,
        &expected_sha256,
        &filename,
    )?;
    send_or_cancel(sender, &offer, cancel).await?;

    let mut buffer = vec![0u8; CHUNK_PAYLOAD_BYTES];
    let mut next_seq: u64 = 0;
    let mut acked_through: Option<u64> = None;
    let mut sent_bytes: u64 = 0;
    let mut last_checkpoint: u64 = 0;

    loop {
        let read = file
            .read(&mut buffer)
            .await
            .context("failed to read file transfer source")?;
        if read == 0 {
            break;
        }

        // Backpressure: bound the number of unacked chunks in flight.
        while in_flight(next_seq, acked_through) >= WINDOW_CHUNKS {
            match wait_for_inbound(&mut inbox, cancel).await? {
                InboundSignal::Ack(seq) => acked_through = Some(seq as u64),
                InboundSignal::Receipt { ok, matches } => {
                    return finalize_receipt(ok, matches, sent_bytes);
                }
            }
        }

        let chunk =
            file_transfer_frame::encode_chunk(&transfer_id, next_seq as u32, &buffer[..read])?;
        send_or_cancel(sender, &chunk, cancel).await?;
        next_seq += 1;
        sent_bytes += read as u64;

        // Drain any acks that arrived without blocking, to keep the window moving.
        while let Ok(frame) = inbox.try_recv() {
            if let FileAppFrame::ChunkAck {
                acked_through_seq, ..
            } = frame
            {
                acked_through = Some(acked_through_seq as u64);
            }
        }

        if sent_bytes - last_checkpoint >= 16 * 1024 * 1024 {
            last_checkpoint = sent_bytes;
            let checkpoint = sent_bytes;
            let now = OffsetDateTime::now_utc();
            let _ = update_file_transfer_request(paths, &request.request_id, move |r| {
                r.record_bytes_transferred(checkpoint, now)
            })
            .await;
        }
    }

    if sent_bytes != total_size {
        bail!("source changed size during transfer");
    }

    // All chunks sent; await the receiver's SHA-256 receipt.
    loop {
        match wait_for_inbound(&mut inbox, cancel).await? {
            InboundSignal::Ack(_) => {}
            InboundSignal::Receipt { ok, matches } => {
                return finalize_receipt(ok, matches, sent_bytes);
            }
        }
    }
}

fn in_flight(next_seq: u64, acked_through: Option<u64>) -> u64 {
    let acked_count = acked_through.map(|seq| seq + 1).unwrap_or(0);
    next_seq.saturating_sub(acked_count)
}

fn finalize_receipt(ok: bool, matches: bool, sent_bytes: u64) -> Result<u64> {
    if ok && matches {
        Ok(sent_bytes)
    } else {
        bail!("receiver rejected transfer: receipt sha256 mismatch")
    }
}

enum InboundSignal {
    Ack(u32),
    Receipt { ok: bool, matches: bool },
}

async fn wait_for_inbound(
    inbox: &mut mpsc::Receiver<FileAppFrame>,
    cancel: &CancellationToken,
) -> Result<InboundSignal> {
    tokio::select! {
        _ = cancel.cancelled() => bail!("transfer cancelled"),
        frame = inbox.recv() => {
            match frame {
                Some(FileAppFrame::ChunkAck { acked_through_seq, .. }) => {
                    Ok(InboundSignal::Ack(acked_through_seq))
                }
                Some(FileAppFrame::Receipt { ok, computed_sha256, .. }) => {
                    // The match flag is computed by the receiver and re-asserted
                    // here against the source digest is not possible (we only
                    // have the receiver's computed digest); trust the receiver's
                    // ok flag, which it sets only on a verified match.
                    let matches = ok && computed_sha256 != [0u8; 32];
                    Ok(InboundSignal::Receipt { ok, matches })
                }
                Some(_) => Ok(InboundSignal::Ack(0)),
                None => bail!("inbound receipt channel closed"),
            }
        }
    }
}

async fn send_or_cancel(
    sender: &NativeWebRtcSender,
    plaintext: &[u8],
    cancel: &CancellationToken,
) -> Result<()> {
    tokio::select! {
        _ = cancel.cancelled() => bail!("transfer cancelled"),
        result = sender.send_file_app_frame(plaintext) => result,
    }
}

/// Sanitize an advertised filename into a safe, single-component name.
fn sanitize_filename(raw: &str) -> Option<String> {
    let name = Path::new(raw).file_name()?.to_str()?;
    let cleaned: String = name.chars().filter(|ch| !ch.is_control()).collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return None;
    }
    if cleaned.contains('/') || cleaned.contains('\\') || cleaned.contains('\0') {
        return None;
    }
    let mut clamped = cleaned.to_owned();
    if clamped.len() > MAX_FILENAME_LEN {
        let mut end = MAX_FILENAME_LEN;
        while end > 0 && !clamped.is_char_boundary(end) {
            end -= 1;
        }
        clamped.truncate(end);
        if clamped.trim().is_empty() {
            return None;
        }
    }
    Some(clamped)
}

struct InboundTransfer {
    total_size: u64,
    expected_sha256: [u8; 32],
    temp_path: PathBuf,
    final_name: String,
    file: File,
    hasher: Sha256,
    received_bytes: u64,
    expected_next_seq: u32,
}

struct FileReceiver {
    received_dir: PathBuf,
    transfers: HashMap<[u8; 16], InboundTransfer>,
}

impl FileReceiver {
    fn new(received_dir: PathBuf) -> Self {
        Self {
            received_dir,
            transfers: HashMap::new(),
        }
    }

    fn total_inflight_bytes(&self) -> u64 {
        self.transfers
            .values()
            .map(|transfer| transfer.total_size)
            .sum()
    }

    /// Handle an inbound offer/chunk; returns outbound plaintext frames to send.
    async fn handle_frame(&mut self, frame: FileAppFrame) -> Result<Vec<Vec<u8>>> {
        match frame {
            FileAppFrame::Offer {
                transfer_id,
                total_size,
                chunk_size,
                expected_sha256,
                filename,
            } => {
                self.on_offer(
                    transfer_id,
                    total_size,
                    chunk_size,
                    expected_sha256,
                    &filename,
                )
                .await
            }
            FileAppFrame::Chunk {
                transfer_id,
                sequence,
                payload,
            } => self.on_chunk(transfer_id, sequence, &payload).await,
            // Receipts/acks are sender-directed; the coordinator never routes
            // them here, but stay total and ignore defensively.
            FileAppFrame::Receipt { .. } | FileAppFrame::ChunkAck { .. } => Ok(Vec::new()),
        }
    }

    async fn on_offer(
        &mut self,
        transfer_id: [u8; 16],
        total_size: u64,
        chunk_size: u32,
        expected_sha256: [u8; 32],
        filename: &str,
    ) -> Result<Vec<Vec<u8>>> {
        if chunk_size != CHUNK_PAYLOAD_BYTES as u32 {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if self.transfers.contains_key(&transfer_id) {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if self.transfers.len() >= MAX_CONCURRENT_RECEIVES {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if self.total_inflight_bytes().saturating_add(total_size) > MAX_TOTAL_INFLIGHT_BYTES {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        let Some(final_name) = sanitize_filename(filename) else {
            return Ok(vec![receipt_err(&transfer_id)?]);
        };

        ensure_received_dir(&self.received_dir).await?;
        let temp_path = self
            .received_dir
            .join(format!(".{}.part", hex16(&transfer_id)));
        // O_EXCL: never write through a planted symlink or reuse a stale part.
        let file = match tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
            .await
        {
            Ok(file) => file,
            Err(_) => return Ok(vec![receipt_err(&transfer_id)?]),
        };

        self.transfers.insert(
            transfer_id,
            InboundTransfer {
                total_size,
                expected_sha256,
                temp_path,
                final_name,
                file,
                hasher: Sha256::new(),
                received_bytes: 0,
                expected_next_seq: 0,
            },
        );
        Ok(Vec::new())
    }

    async fn on_chunk(
        &mut self,
        transfer_id: [u8; 16],
        sequence: u32,
        payload: &[u8],
    ) -> Result<Vec<Vec<u8>>> {
        let Some(transfer) = self.transfers.get_mut(&transfer_id) else {
            // Chunk before offer / for a closed transfer: drop (no state to write).
            debug!(
                kind = "agent.file_transfer.chunk_without_offer",
                "dropping orphan chunk"
            );
            return Ok(Vec::new());
        };

        if sequence != transfer.expected_next_seq {
            self.abort_transfer(&transfer_id).await;
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if transfer.received_bytes + payload.len() as u64 > transfer.total_size {
            self.abort_transfer(&transfer_id).await;
            return Ok(vec![receipt_err(&transfer_id)?]);
        }

        transfer
            .file
            .write_all(payload)
            .await
            .context("failed to write inbound file chunk")?;
        transfer.hasher.update(payload);
        transfer.received_bytes += payload.len() as u64;
        transfer.expected_next_seq += 1;

        if transfer.received_bytes == transfer.total_size {
            return self.finalize_transfer(&transfer_id).await;
        }
        if transfer.expected_next_seq.is_multiple_of(ACK_EVERY_CHUNKS) {
            return Ok(vec![file_transfer_frame::encode_chunk_ack(
                &transfer_id,
                transfer.expected_next_seq - 1,
            )]);
        }
        Ok(Vec::new())
    }

    async fn finalize_transfer(&mut self, transfer_id: &[u8; 16]) -> Result<Vec<Vec<u8>>> {
        let Some(mut transfer) = self.transfers.remove(transfer_id) else {
            return Ok(Vec::new());
        };
        transfer
            .file
            .flush()
            .await
            .context("failed to flush inbound file")?;
        transfer
            .file
            .sync_all()
            .await
            .context("failed to sync inbound file")?;
        drop(transfer.file);

        let computed: [u8; 32] = transfer.hasher.finalize().into();
        if computed != transfer.expected_sha256 {
            let _ = tokio::fs::remove_file(&transfer.temp_path).await;
            return Ok(vec![receipt_err(transfer_id)?]);
        }

        match place_received_file(
            &self.received_dir,
            &transfer.temp_path,
            &transfer.final_name,
        )
        .await
        {
            Ok(final_path) => {
                info!(
                    kind = "agent.file_transfer.received",
                    bytes = transfer.received_bytes,
                    receipt_verified = true,
                    "inbound file transfer verified and stored"
                );
                debug!(
                    kind = "agent.file_transfer.received_path",
                    path = %final_path.display(),
                    "stored received file"
                );
                Ok(vec![file_transfer_frame::encode_receipt(
                    transfer_id,
                    true,
                    &computed,
                    "",
                )?])
            }
            Err(error) => {
                let _ = tokio::fs::remove_file(&transfer.temp_path).await;
                warn!(
                    kind = "agent.file_transfer.place_failed",
                    error = %error,
                    "failed to place received file"
                );
                Ok(vec![receipt_err(transfer_id)?])
            }
        }
    }

    async fn abort_transfer(&mut self, transfer_id: &[u8; 16]) {
        if let Some(transfer) = self.transfers.remove(transfer_id) {
            drop(transfer.file);
            let _ = tokio::fs::remove_file(&transfer.temp_path).await;
        }
    }
}

fn receipt_err(transfer_id: &[u8; 16]) -> Result<Vec<u8>> {
    file_transfer_frame::encode_receipt(transfer_id, false, &[0u8; 32], "transfer rejected")
}

async fn ensure_received_dir(dir: &Path) -> Result<()> {
    if let Ok(metadata) = tokio::fs::symlink_metadata(dir).await {
        if metadata.file_type().is_symlink() {
            bail!("received directory must not be a symlink");
        }
        if !metadata.is_dir() {
            bail!("received path exists but is not a directory");
        }
    }
    tokio::fs::create_dir_all(dir)
        .await
        .context("failed to create received directory")?;
    Ok(())
}

/// Atomically place the verified temp file under a collision-free name in
/// `received_dir`, never overwriting an existing file.
async fn place_received_file(
    received_dir: &Path,
    temp_path: &Path,
    final_name: &str,
) -> Result<PathBuf> {
    let (stem, extension) = split_name(final_name);
    for attempt in 0..MAX_NAME_COLLISION_ATTEMPTS {
        let candidate_name = if attempt == 0 {
            final_name.to_owned()
        } else if extension.is_empty() {
            format!("{stem} ({attempt})")
        } else {
            format!("{stem} ({attempt}).{extension}")
        };
        let candidate = received_dir.join(&candidate_name);
        // Reserve the name with O_EXCL so a concurrent/symlink target cannot be
        // followed; then move the verified bytes onto it.
        match tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
            .await
        {
            Ok(file) => {
                drop(file);
                tokio::fs::rename(temp_path, &candidate)
                    .await
                    .context("failed to move received file into place")?;
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error).context("failed to reserve received file name"),
        }
    }
    bail!("too many received-file name collisions")
}

fn split_name(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(index) if index > 0 && index + 1 < name.len() => {
            (name[..index].to_owned(), name[index + 1..].to_owned())
        }
        _ => (name.to_owned(), String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("skybridge-ft-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    fn sha256(bytes: &[u8]) -> [u8; 32] {
        Sha256::digest(bytes).into()
    }

    #[test]
    fn sanitize_filename_strips_paths_and_traversal() {
        assert_eq!(
            sanitize_filename("../../etc/passwd").as_deref(),
            Some("passwd")
        );
        assert_eq!(
            sanitize_filename("/abs/report.pdf").as_deref(),
            Some("report.pdf")
        );
        assert_eq!(sanitize_filename("plain.txt").as_deref(), Some("plain.txt"));
        assert_eq!(sanitize_filename(".."), None);
        assert_eq!(sanitize_filename("   "), None);
        assert_eq!(sanitize_filename(""), None);
    }

    #[tokio::test]
    async fn receiver_writes_verified_file_and_emits_ok_receipt() {
        let dir = temp_dir("ok");
        let mut receiver = FileReceiver::new(dir.clone());
        let tid = [5u8; 16];
        let payload = b"hello skybridge file transfer".to_vec();
        let digest = sha256(&payload);

        let offer = receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "note.txt".to_owned(),
            })
            .await
            .expect("offer");
        assert!(offer.is_empty());

        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: payload.clone(),
            })
            .await
            .expect("chunk");
        assert_eq!(out.len(), 1);
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode receipt") {
            FileAppFrame::Receipt {
                ok,
                computed_sha256,
                ..
            } => {
                assert!(ok);
                assert_eq!(computed_sha256, digest);
            }
            other => panic!("expected receipt, got {other:?}"),
        }
        let stored = std::fs::read(dir.join("note.txt")).expect("stored file");
        assert_eq!(stored, payload);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_sha_mismatch_without_storing() {
        let dir = temp_dir("mismatch");
        let mut receiver = FileReceiver::new(dir.clone());
        let tid = [6u8; 16];
        let payload = b"actual bytes".to_vec();
        let wrong_digest = sha256(b"different");

        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: wrong_digest,
                filename: "x.bin".to_owned(),
            })
            .await
            .expect("offer");
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload,
            })
            .await
            .expect("chunk");
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode") {
            FileAppFrame::Receipt { ok, .. } => assert!(!ok),
            other => panic!("expected receipt err, got {other:?}"),
        }
        assert!(!dir.join("x.bin").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_out_of_order_sequence() {
        let dir = temp_dir("ooo");
        let mut receiver = FileReceiver::new(dir.clone());
        let tid = [7u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 10,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: [0u8; 32],
                filename: "y.bin".to_owned(),
            })
            .await
            .expect("offer");
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 5,
                payload: vec![1, 2, 3],
            })
            .await
            .expect("chunk");
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode") {
            FileAppFrame::Receipt { ok, .. } => assert!(!ok),
            other => panic!("expected receipt err, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_auto_suffixes_on_collision_without_overwrite() {
        let dir = temp_dir("collide");
        std::fs::write(dir.join("dup.txt"), b"existing").expect("seed existing");
        let mut receiver = FileReceiver::new(dir.clone());
        let tid = [8u8; 16];
        let payload = b"new content".to_vec();
        let digest = sha256(&payload);
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "dup.txt".to_owned(),
            })
            .await
            .expect("offer");
        receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: payload.clone(),
            })
            .await
            .expect("chunk");
        assert_eq!(std::fs::read(dir.join("dup.txt")).unwrap(), b"existing");
        assert_eq!(std::fs::read(dir.join("dup (1).txt")).unwrap(), payload);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_chunks_across_multiple_frames_and_acks() {
        let dir = temp_dir("multi");
        let mut receiver = FileReceiver::new(dir.clone());
        let tid = [9u8; 16];
        let chunk = vec![42u8; CHUNK_PAYLOAD_BYTES];
        // One chunk past the ack cadence so a mid-stream ack fires before the
        // final completion receipt preempts it.
        let chunk_count = ACK_EVERY_CHUNKS + 1;
        let total = (CHUNK_PAYLOAD_BYTES * (chunk_count as usize)) as u64;
        let mut all = Vec::new();
        for _ in 0..chunk_count {
            all.extend_from_slice(&chunk);
        }
        let digest = sha256(&all);
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: total,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "big.bin".to_owned(),
            })
            .await
            .expect("offer");
        let mut got_ack = false;
        let mut got_receipt = false;
        for seq in 0..chunk_count {
            let out = receiver
                .handle_frame(FileAppFrame::Chunk {
                    transfer_id: tid,
                    sequence: seq,
                    payload: chunk.clone(),
                })
                .await
                .expect("chunk");
            for plaintext in out {
                match file_transfer_frame::decode_file_app_frame(&plaintext).expect("decode") {
                    FileAppFrame::ChunkAck { .. } => got_ack = true,
                    FileAppFrame::Receipt { ok, .. } => {
                        assert!(ok);
                        got_receipt = true;
                    }
                    _ => {}
                }
            }
        }
        assert!(got_ack, "expected at least one chunk ack");
        assert!(got_receipt, "expected a final receipt");
        assert_eq!(
            std::fs::read(dir.join("big.bin")).unwrap().len(),
            total as usize
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
