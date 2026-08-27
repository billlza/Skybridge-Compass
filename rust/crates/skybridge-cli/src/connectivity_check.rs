use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Map, Value};

use crate::{
    ConnectivityCheckArgs, DoctorProbeReport, ensure_probe_report_passed,
    print_doctor_probe_report, simple_doctor_check,
};

const MAC_LOG_FILE: &str = "mac-product-session.log";
const MAC_CAPTURE_FILE: &str = "mac-product-session-capture.json";
const IOS_LOG_FILE: &str = "ios-product-session.log";
const IOS_CAPTURE_FILE: &str = "ios-product-session-capture.json";
const RELEASE_ACCEPTANCE_FILE: &str = "release-acceptance.json";
const MAC_PRODUCT: &str = "SkyBridgeCompassApp";
const IOS_PRODUCT: &str = "SkyBridgeCompassiOS";
const IOS_EXECUTABLE: &str = "SkyBridgeCompass-iOS";
const SUBSYSTEM: &str = "com.skybridge.compass.release-evidence";
const CATEGORY: &str = "ProductSession";
const CAPTURE_PROFILE: &str = "skybridge-product-release-evidence-capture";
const MAC_CAPTURE_MODE: &str = "unified-log-process-bound";
const IOS_CAPTURE_MODE: &str = "devicectl-unified-log-process-bound";
const MAX_LOG_BYTES: u64 = 8 * 1024 * 1024;
const MAX_CAPTURE_BYTES: u64 = 64 * 1024;
const MAX_LINE_BYTES: usize = 4096;
const MAX_EVENTS: usize = 4096;
const MAX_EVENTS_PER_ATTEMPT: usize = 20;

const OWNER_FIELDS: &[&str] = &[
    "transport",
    "attempt_ref",
    "owner",
    "generation",
    "role",
    "localProfile",
    "offeredProfiles",
    "requirePQC",
    "allowClassicFallback",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Product {
    Mac,
    Ios,
}

impl Product {
    fn owner(self) -> &'static str {
        match self {
            Self::Mac => MAC_PRODUCT,
            Self::Ios => IOS_PRODUCT,
        }
    }

    fn log_file(self) -> &'static str {
        match self {
            Self::Mac => MAC_LOG_FILE,
            Self::Ios => IOS_LOG_FILE,
        }
    }

    fn capture_file(self) -> &'static str {
        match self {
            Self::Mac => MAC_CAPTURE_FILE,
            Self::Ios => IOS_CAPTURE_FILE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Profile {
    XWing,
    Pqc,
}

impl Profile {
    fn parse(value: &str, label: &str) -> Result<Self> {
        match value {
            "xwing" => Ok(Self::XWing),
            "pqc" => Ok(Self::Pqc),
            _ => bail!("{label} must be xwing or pqc"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Initiator,
    Responder,
}

impl Role {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "initiator" => Ok(Self::Initiator),
            "responder" => Ok(Self::Responder),
            _ => bail!("connectivity role must be initiator or responder"),
        }
    }

    fn complements(self, other: Self) -> bool {
        matches!(
            (self, other),
            (Self::Initiator, Self::Responder) | (Self::Responder, Self::Initiator)
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EventKind {
    Started,
    Authenticated,
    Endpoint,
    PolicyRejected,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ConnectivityEvent {
    kind: EventKind,
    attempt_reference: String,
    owner: Product,
    generation: u64,
    role: Role,
    local_profile: Profile,
    offered_profiles: BTreeSet<Profile>,
    session_reference: Option<String>,
    attempt_profile: Option<Profile>,
    suite: Option<String>,
}

#[derive(Debug, Clone)]
struct ConnectivityAttempt {
    owner: Product,
    attempt_reference: String,
    role: Role,
    local_profile: Profile,
    offered_profiles: BTreeSet<Profile>,
    events: Vec<ConnectivityEvent>,
}

impl ConnectivityAttempt {
    fn is_success(&self) -> bool {
        self.event_kinds()
            == [
                EventKind::Started,
                EventKind::Authenticated,
                EventKind::Endpoint,
            ]
    }

    fn is_expected_rejection(&self) -> bool {
        self.event_kinds() == [EventKind::Started, EventKind::PolicyRejected]
    }

    fn event_kinds(&self) -> Vec<EventKind> {
        self.events.iter().map(|event| event.kind).collect()
    }

    fn authenticated(&self) -> &ConnectivityEvent {
        &self.events[1]
    }

    fn endpoint(&self) -> &ConnectivityEvent {
        &self.events[2]
    }
}

#[derive(Debug)]
struct ConnectivityEvidence {
    mac_event_count: usize,
    ios_event_count: usize,
    success_pairs: BTreeSet<(Profile, Profile)>,
    success_sessions: BTreeSet<String>,
    rejection_products: BTreeSet<Product>,
}

pub(crate) async fn check_connectivity(args: ConnectivityCheckArgs) -> Result<()> {
    let as_json = args.output.json;
    let report = build_connectivity_check_report(&args)?;
    print_doctor_probe_report(&report, as_json)?;
    ensure_probe_report_passed(&report, "connectivity check failed")
}

pub(crate) fn build_connectivity_check_report(
    args: &ConnectivityCheckArgs,
) -> Result<DoctorProbeReport> {
    let evidence = read_connectivity_evidence(&args.artifact_dir)?;
    let details = format!(
        "macEvents={} iosEvents={} successPairs={} successSessions={} signedClassicRejections={}",
        evidence.mac_event_count,
        evidence.ios_event_count,
        evidence.success_pairs.len(),
        evidence.success_sessions.len(),
        evidence.rejection_products.len(),
    );
    let checks = vec![
        simple_doctor_check(
            "connectivity_candidate_bound_product_logs",
            true,
            "info",
            details.clone(),
        ),
        simple_doctor_check(
            "connectivity_three_success_pairs",
            true,
            "info",
            details.clone(),
        ),
        simple_doctor_check("connectivity_endpoint_join", true, "info", details.clone()),
        simple_doctor_check(
            "connectivity_actual_offer_suite_family",
            true,
            "info",
            details.clone(),
        ),
        simple_doctor_check(
            "connectivity_signed_classic_rejections",
            true,
            "info",
            details,
        ),
    ];

    Ok(DoctorProbeReport {
        target: format!("connectivity artifact={}", args.artifact_dir.display()),
        fault_stage: None,
        checks,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}

fn read_connectivity_evidence(artifact_dir: &Path) -> Result<ConnectivityEvidence> {
    let artifact_metadata = fs::symlink_metadata(artifact_dir).with_context(|| {
        format!(
            "unable to inspect connectivity artifact dir {}",
            artifact_dir.display()
        )
    })?;
    if artifact_metadata.file_type().is_symlink() || !artifact_metadata.is_dir() {
        bail!(
            "connectivity artifact dir must be a real directory: {}",
            artifact_dir.display()
        );
    }
    let mac_events = read_product_log(artifact_dir, Product::Mac)?;
    let ios_events = read_product_log(artifact_dir, Product::Ios)?;
    validate_capture_manifest(artifact_dir, Product::Mac, mac_events.len())?;
    let ios_archive_binding =
        validate_capture_manifest(artifact_dir, Product::Ios, ios_events.len())?
            .ok_or_else(|| anyhow!("iOS product capture has no archive binding"))?;
    validate_release_acceptance_binding(artifact_dir, &ios_archive_binding)?;
    let mac_event_count = mac_events.len();
    let ios_event_count = ios_events.len();
    let mac_attempts = group_attempts(mac_events, Product::Mac)?;
    let ios_attempts = group_attempts(ios_events, Product::Ios)?;
    let (success_pairs, success_sessions, rejection_products) =
        join_attempts(&mac_attempts, &ios_attempts)?;
    Ok(ConnectivityEvidence {
        mac_event_count,
        ios_event_count,
        success_pairs,
        success_sessions,
        rejection_products,
    })
}

fn read_product_log(artifact_dir: &Path, product: Product) -> Result<Vec<ConnectivityEvent>> {
    let path = artifact_dir.join(product.log_file());
    let content = read_regular_file(&path, MAX_LOG_BYTES)?;
    if !content.ends_with(b"\n") || content.contains(&b'\r') {
        bail!("{} must use LF termination", product.log_file());
    }
    if !content.is_ascii() {
        bail!("{} must be ASCII", product.log_file());
    }
    let text = std::str::from_utf8(&content).context("ASCII product log was not UTF-8")?;
    let lines = text[..text.len() - 1].split('\n').collect::<Vec<_>>();
    if lines.is_empty() || lines.len() > MAX_EVENTS {
        bail!("{} event count must be 1-{MAX_EVENTS}", product.log_file());
    }
    lines
        .into_iter()
        .enumerate()
        .map(|(index, line)| parse_event_line(line, index + 1, product))
        .collect()
}

fn read_regular_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>> {
    let path_metadata_before = fs::symlink_metadata(path).with_context(|| {
        format!(
            "unable to inspect required evidence file {}",
            path.display()
        )
    })?;
    validate_evidence_metadata(&path_metadata_before, path, maximum_bytes)?;
    let file = open_evidence_file_no_follow(path)?;
    read_opened_regular_file(path, maximum_bytes, &path_metadata_before, file)
}

fn read_opened_regular_file(
    path: &Path,
    maximum_bytes: u64,
    path_metadata_before: &Metadata,
    mut file: File,
) -> Result<Vec<u8>> {
    let opened_metadata_before = file
        .metadata()
        .with_context(|| format!("failed to inspect opened evidence file {}", path.display()))?;
    validate_evidence_metadata(&opened_metadata_before, path, maximum_bytes)?;
    if !same_stable_evidence_metadata(path_metadata_before, &opened_metadata_before) {
        bail!(
            "evidence file changed before it was opened: {}",
            path.display()
        );
    }
    #[cfg(windows)]
    let opened_identity_before = {
        let identity = opened_evidence_identity(&file, path)?;
        if identity.number_of_links != 1 {
            bail!(
                "required evidence must be a single-link regular file: {}",
                path.display()
            );
        }
        identity
    };

    let mut content = Vec::with_capacity(opened_metadata_before.len() as usize);
    file.by_ref()
        .take(maximum_bytes + 1)
        .read_to_end(&mut content)
        .with_context(|| format!("failed to read evidence file {}", path.display()))?;
    if content.len() as u64 != opened_metadata_before.len() {
        bail!("evidence file changed while reading: {}", path.display());
    }

    let opened_metadata_after = file.metadata().with_context(|| {
        format!(
            "failed to re-inspect opened evidence file {}",
            path.display()
        )
    })?;
    let path_metadata_after = fs::symlink_metadata(path).with_context(|| {
        format!(
            "unable to re-inspect required evidence file {}",
            path.display()
        )
    })?;
    validate_evidence_metadata(&opened_metadata_after, path, maximum_bytes)?;
    validate_evidence_metadata(&path_metadata_after, path, maximum_bytes)?;
    if !same_stable_evidence_metadata(&opened_metadata_before, &opened_metadata_after)
        || !same_stable_evidence_metadata(&opened_metadata_after, &path_metadata_after)
    {
        bail!("evidence file changed while reading: {}", path.display());
    }
    #[cfg(windows)]
    {
        // Bind the handle identity across the read, and bind the path to the
        // same physical file by re-opening it and comparing identities — the
        // stable-std replacement for stat-level volume/file-index equality.
        let opened_identity_after = opened_evidence_identity(&file, path)?;
        if opened_identity_after != opened_identity_before
            || opened_identity_after.number_of_links != 1
        {
            bail!("evidence file changed while reading: {}", path.display());
        }
        let reopened = open_evidence_file_no_follow(path)?;
        let reopened_identity = opened_evidence_identity(&reopened, path)?;
        if reopened_identity != opened_identity_before {
            bail!("evidence file changed while reading: {}", path.display());
        }
    }
    Ok(content)
}

fn validate_evidence_metadata(metadata: &Metadata, path: &Path, maximum_bytes: u64) -> Result<()> {
    if metadata.file_type().is_symlink() || !metadata.is_file() || !path_level_single_link(metadata)
    {
        bail!(
            "required evidence must be a single-link regular file: {}",
            path.display()
        );
    }
    if metadata.len() == 0 || metadata.len() > maximum_bytes {
        bail!(
            "evidence file size must be 1-{maximum_bytes} bytes: {}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(unix)]
fn path_level_single_link(metadata: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    metadata.nlink() == 1
}

#[cfg(windows)]
fn path_level_single_link(metadata: &Metadata) -> bool {
    // Stat-level link counts on Windows need the unstable windows_by_handle
    // std feature; the single-link rule is enforced from the opened handle
    // in read_opened_regular_file instead, which is the stronger check.
    let _ = metadata;
    true
}

#[cfg(not(any(unix, windows)))]
fn path_level_single_link(_metadata: &Metadata) -> bool {
    false
}

#[cfg(unix)]
fn same_stable_evidence_metadata(left: &Metadata, right: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.mode() == right.mode()
        && left.nlink() == right.nlink()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
}

#[cfg(windows)]
fn same_stable_evidence_metadata(left: &Metadata, right: &Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    // Volume/file-index/link identity at the stat level needs the unstable
    // windows_by_handle std feature; file identity and the single-link rule
    // are enforced from the opened handle instead, so this compares the
    // stable mutation-visible fields.
    left.file_attributes() == right.file_attributes()
        && left.len() == right.len()
        && left.last_write_time() == right.last_write_time()
        && left.creation_time() == right.creation_time()
}

#[cfg(windows)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct OpenedEvidenceIdentity {
    volume_serial_number: u32,
    file_index_high: u32,
    file_index_low: u32,
    number_of_links: u32,
}

#[cfg(windows)]
fn opened_evidence_identity(file: &File, path: &Path) -> Result<OpenedEvidenceIdentity> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
    };

    let mut information: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: the handle is owned by `file` and stays open for the duration
    // of the call; the structure is plain data the kernel fills on success.
    let succeeded =
        unsafe { GetFileInformationByHandle(file.as_raw_handle() as _, &mut information) };
    if succeeded == 0 {
        bail!(
            "unable to read the opened evidence file identity: {}",
            path.display()
        );
    }
    Ok(OpenedEvidenceIdentity {
        volume_serial_number: information.dwVolumeSerialNumber,
        file_index_high: information.nFileIndexHigh,
        file_index_low: information.nFileIndexLow,
        number_of_links: information.nNumberOfLinks,
    })
}

#[cfg(not(any(unix, windows)))]
fn same_stable_evidence_metadata(_left: &Metadata, _right: &Metadata) -> bool {
    false
}

fn open_evidence_file_no_follow(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);

    #[cfg(all(unix, target_vendor = "apple"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        const O_NOFOLLOW: i32 = 0x0000_0100;
        options.custom_flags(O_NOFOLLOW);
    }
    #[cfg(all(unix, any(target_os = "linux", target_os = "android")))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        const O_NOFOLLOW: i32 = 0x0002_0000;
        options.custom_flags(O_NOFOLLOW);
    }
    #[cfg(all(
        unix,
        any(
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly"
        )
    ))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        const O_NOFOLLOW: i32 = 0x0000_0100;
        options.custom_flags(O_NOFOLLOW);
    }
    #[cfg(all(unix, any(target_os = "solaris", target_os = "illumos")))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        const O_NOFOLLOW: i32 = 0x0002_0000;
        options.custom_flags(O_NOFOLLOW);
    }
    #[cfg(all(
        unix,
        not(any(
            target_vendor = "apple",
            target_os = "linux",
            target_os = "android",
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly",
            target_os = "solaris",
            target_os = "illumos"
        ))
    ))]
    {
        bail!("secure no-follow evidence reads are unsupported on this Unix target");
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    #[cfg(not(any(unix, windows)))]
    {
        bail!("secure no-follow evidence reads are unsupported on this target");
    }

    options.open(path).with_context(|| {
        format!(
            "failed to open evidence file without following links: {}",
            path.display()
        )
    })
}

fn parse_event_line(line: &str, line_number: usize, product: Product) -> Result<ConnectivityEvent> {
    if line.is_empty()
        || line.len() > MAX_LINE_BYTES
        || !line.is_ascii()
        || line.split(' ').any(str::is_empty)
    {
        bail!("line {line_number} is not canonical single-space ASCII");
    }
    let mut tokens = line.split(' ');
    let event_name = tokens
        .next()
        .ok_or_else(|| anyhow!("line {line_number} has no event name"))?;
    let kind = match event_name {
        "connectivityAttemptStarted" => EventKind::Started,
        "connectivityAttemptAuthenticated" => EventKind::Authenticated,
        "connectivityEndpoint" => EventKind::Endpoint,
        "connectivityPolicyRejected" => EventKind::PolicyRejected,
        "connectivityAttemptFailed" => EventKind::Failed,
        _ => bail!("line {line_number} has unsupported connectivity product event {event_name}"),
    };
    let mut fields = BTreeMap::new();
    let mut ordered_keys = Vec::new();
    for token in tokens {
        let (key, value) = token
            .split_once('=')
            .ok_or_else(|| anyhow!("line {line_number} has a malformed field"))?;
        if value.contains('=')
            || !valid_field_key(key)
            || !valid_field_value(value)
            || fields.insert(key, value).is_some()
        {
            bail!("line {line_number} has an invalid or duplicate field");
        }
        ordered_keys.push(key);
    }
    let expected_keys = expected_event_keys(kind);
    if ordered_keys != expected_keys {
        bail!("line {line_number} fields are not the fixed {event_name} schema");
    }
    if required_field(&fields, "transport", line_number)? != "p2p" {
        bail!("line {line_number} connectivity transport must be p2p");
    }
    if required_field(&fields, "owner", line_number)? != product.owner() {
        bail!("line {line_number} is not owned by the expected shipping product");
    }
    let attempt_reference = required_field(&fields, "attempt_ref", line_number)?;
    if !valid_reference(attempt_reference, "at1:") {
        bail!("line {line_number} has an invalid attempt_ref");
    }
    let generation = parse_positive_u64(
        required_field(&fields, "generation", line_number)?,
        "generation",
        line_number,
    )?;
    let role = Role::parse(required_field(&fields, "role", line_number)?)?;
    let local_profile = Profile::parse(
        required_field(&fields, "localProfile", line_number)?,
        "localProfile",
    )?;
    let offered_profiles =
        parse_offered_profiles(required_field(&fields, "offeredProfiles", line_number)?)?;
    if !offered_profiles.contains(&local_profile)
        || required_field(&fields, "requirePQC", line_number)? != "1"
        || required_field(&fields, "allowClassicFallback", line_number)? != "0"
    {
        bail!("line {line_number} has an inconsistent strict local offer");
    }

    let session_reference = fields.get("session_ref").map(ToString::to_string);
    if session_reference
        .as_deref()
        .is_some_and(|reference| !valid_reference(reference, "ev1:"))
    {
        bail!("line {line_number} has an invalid session_ref");
    }
    let attempt_profile = fields
        .get("attemptProfile")
        .map(|value| Profile::parse(value, "attemptProfile"))
        .transpose()?;
    let suite = fields.get("suite").map(ToString::to_string);

    validate_terminal_fields(
        kind,
        &fields,
        role,
        attempt_profile,
        suite.as_deref(),
        line_number,
    )?;
    Ok(ConnectivityEvent {
        kind,
        attempt_reference: attempt_reference.to_owned(),
        owner: product,
        generation,
        role,
        local_profile,
        offered_profiles,
        session_reference,
        attempt_profile,
        suite,
    })
}

fn expected_event_keys(kind: EventKind) -> Vec<&'static str> {
    match kind {
        EventKind::Started => OWNER_FIELDS.iter().copied().chain(["result"]).collect(),
        EventKind::Authenticated => OWNER_FIELDS
            .iter()
            .copied()
            .chain(["session_ref", "attemptProfile", "result"])
            .collect(),
        EventKind::Endpoint => vec![
            "transport",
            "session_ref",
            "attempt_ref",
            "owner",
            "generation",
            "role",
            "localProfile",
            "offeredProfiles",
            "attemptProfile",
            "suite",
            "requirePQC",
            "allowClassicFallback",
            "result",
        ],
        EventKind::PolicyRejected => OWNER_FIELDS
            .iter()
            .copied()
            .chain([
                "peerOfferedProfiles",
                "peerOfferSignature",
                "reason",
                "result",
            ])
            .collect(),
        EventKind::Failed => OWNER_FIELDS
            .iter()
            .copied()
            .chain(["reason", "result"])
            .collect(),
    }
}

fn required_field<'a>(
    fields: &'a BTreeMap<&str, &str>,
    key: &str,
    line_number: usize,
) -> Result<&'a str> {
    fields
        .get(key)
        .copied()
        .ok_or_else(|| anyhow!("line {line_number} is missing {key}"))
}

fn valid_field_key(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes.next().is_some_and(|byte| byte.is_ascii_alphabetic())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn valid_field_value(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'+' | b'.' | b',' | b'-')
        })
}

fn valid_reference(value: &str, prefix: &str) -> bool {
    value.len() == 36
        && value.starts_with(prefix)
        && value[4..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn parse_positive_u64(value: &str, label: &str, line_number: usize) -> Result<u64> {
    if value.starts_with('0') || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("line {line_number} {label} must be a positive decimal integer");
    }
    let parsed = value
        .parse::<u64>()
        .with_context(|| format!("line {line_number} {label} exceeds u64"))?;
    if parsed == 0 {
        bail!("line {line_number} {label} must be positive");
    }
    Ok(parsed)
}

fn parse_offered_profiles(value: &str) -> Result<BTreeSet<Profile>> {
    match value {
        "xwing" => Ok(BTreeSet::from([Profile::XWing])),
        "pqc" => Ok(BTreeSet::from([Profile::Pqc])),
        "pqc+xwing" => Ok(BTreeSet::from([Profile::Pqc, Profile::XWing])),
        _ => bail!("offeredProfiles must be xwing, pqc, or pqc+xwing"),
    }
}

fn suite_family(suite: &str) -> Option<Profile> {
    match suite {
        "X-Wing" => Some(Profile::XWing),
        "Q-Periapt-ABI2-PolicyBound" | "ML-KEM-768" | "ML-KEM-768-FS" => Some(Profile::Pqc),
        _ => None,
    }
}

fn validate_terminal_fields(
    kind: EventKind,
    fields: &BTreeMap<&str, &str>,
    role: Role,
    attempt_profile: Option<Profile>,
    suite: Option<&str>,
    line_number: usize,
) -> Result<()> {
    let result = required_field(fields, "result", line_number)?;
    match kind {
        EventKind::Started if result == "started" => Ok(()),
        EventKind::Authenticated if result == "authenticated" && attempt_profile.is_some() => {
            Ok(())
        }
        EventKind::Endpoint
            if result == "success"
                && suite.and_then(suite_family).is_some()
                && suite.and_then(suite_family) == attempt_profile =>
        {
            Ok(())
        }
        EventKind::PolicyRejected
            if role == Role::Responder
                && required_field(fields, "peerOfferedProfiles", line_number)? == "classic"
                && required_field(fields, "peerOfferSignature", line_number)? == "verified"
                && required_field(fields, "reason", line_number)?
                    == "strict-pqc-rejects-classic"
                && result == "rejected" =>
        {
            Ok(())
        }
        EventKind::Failed if result == "failed" => Ok(()),
        _ => bail!("line {line_number} has an invalid connectivity terminal"),
    }
}

fn group_attempts(
    events: Vec<ConnectivityEvent>,
    product: Product,
) -> Result<BTreeMap<String, ConnectivityAttempt>> {
    let mut grouped: BTreeMap<String, Vec<ConnectivityEvent>> = BTreeMap::new();
    let mut generation_to_attempt = BTreeMap::new();
    for event in events {
        if event.owner != product {
            bail!("product log contains an event from a different owner");
        }
        if let Some(previous) =
            generation_to_attempt.insert(event.generation, event.attempt_reference.clone())
            && previous != event.attempt_reference
        {
            bail!("shipping product reuses one local generation across attempts");
        }
        grouped
            .entry(event.attempt_reference.clone())
            .or_default()
            .push(event);
    }

    grouped
        .into_iter()
        .map(|(attempt_reference, attempt_events)| {
            if attempt_events.len() > MAX_EVENTS_PER_ATTEMPT {
                bail!(
                    "connectivity attempt exceeds the fixed {MAX_EVENTS_PER_ATTEMPT}-event product limit"
                );
            }
            let first = attempt_events
                .first()
                .ok_or_else(|| anyhow!("connectivity attempt is empty"))?;
            if attempt_events.iter().any(|event| {
                event.owner != first.owner
                    || event.generation != first.generation
                    || event.role != first.role
                    || event.local_profile != first.local_profile
                    || event.offered_profiles != first.offered_profiles
            }) {
                bail!("connectivity attempt changes locally owned fields");
            }
            let attempt = ConnectivityAttempt {
                owner: first.owner,
                attempt_reference: attempt_reference.clone(),
                role: first.role,
                local_profile: first.local_profile,
                offered_profiles: first.offered_profiles.clone(),
                events: attempt_events,
            };
            if attempt.is_success() {
                let authenticated = attempt.authenticated();
                let endpoint = attempt.endpoint();
                if authenticated.session_reference != endpoint.session_reference
                    || authenticated.attempt_profile != endpoint.attempt_profile
                {
                    bail!(
                        "connectivity endpoint does not match its authenticated terminal"
                    );
                }
                let family = endpoint.suite.as_deref().and_then(suite_family);
                if family.is_none() || !attempt.offered_profiles.contains(&family.unwrap()) {
                    bail!("negotiated suite family was absent from the actual local offer");
                }
            } else if !attempt.is_expected_rejection() {
                bail!("connectivity attempt has an invalid or failed lifecycle");
            }
            Ok((attempt_reference, attempt))
        })
        .collect()
}

type JoinResult = (
    BTreeSet<(Profile, Profile)>,
    BTreeSet<String>,
    BTreeSet<Product>,
);

fn join_attempts(
    mac_attempts: &BTreeMap<String, ConnectivityAttempt>,
    ios_attempts: &BTreeMap<String, ConnectivityAttempt>,
) -> Result<JoinResult> {
    let all_references = mac_attempts
        .keys()
        .chain(ios_attempts.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut success_pairs = BTreeSet::new();
    let mut success_sessions = BTreeSet::new();
    let mut rejection_products = BTreeSet::new();

    for reference in all_references {
        let mac = mac_attempts.get(&reference);
        let ios = ios_attempts.get(&reference);
        let has_success = mac.is_some_and(ConnectivityAttempt::is_success)
            || ios.is_some_and(ConnectivityAttempt::is_success);
        if has_success {
            let (mac, ios) = match (mac, ios) {
                (Some(mac), Some(ios)) if mac.is_success() && ios.is_success() => (mac, ios),
                _ => bail!(
                    "successful connectivity attempt requires exact Mac and iOS product endpoints"
                ),
            };
            if mac.attempt_reference != ios.attempt_reference
                || !mac.role.complements(ios.role)
                || mac.authenticated().session_reference != ios.authenticated().session_reference
                || mac.endpoint().session_reference != ios.endpoint().session_reference
                || mac.endpoint().suite != ios.endpoint().suite
                || mac.endpoint().attempt_profile != ios.endpoint().attempt_profile
            {
                bail!(
                    "paired connectivity endpoints disagree on attempt, role, session, suite, or attempt profile"
                );
            }
            let session = mac
                .endpoint()
                .session_reference
                .clone()
                .ok_or_else(|| anyhow!("successful endpoint has no session_ref"))?;
            if !success_sessions.insert(session) {
                bail!("successful connectivity pairs must use distinct authenticated sessions");
            }
            if !success_pairs.insert((mac.local_profile, ios.local_profile)) {
                bail!("connectivity evidence duplicates a successful profile pair");
            }
            continue;
        }

        let rejection = match (mac, ios) {
            (Some(attempt), None) | (None, Some(attempt)) if attempt.is_expected_rejection() => {
                attempt
            }
            _ => bail!(
                "expected classic rejection must be one shipping responder started/rejected pair"
            ),
        };
        if rejection.role != Role::Responder || !rejection_products.insert(rejection.owner) {
            bail!("expected classic rejections require one responder per shipping product");
        }
    }

    let expected_pairs = BTreeSet::from([
        (Profile::XWing, Profile::XWing),
        (Profile::XWing, Profile::Pqc),
        (Profile::Pqc, Profile::XWing),
    ]);
    if success_pairs != expected_pairs || success_sessions.len() != 3 {
        bail!("connectivity evidence does not cover the exact three success profile pairs");
    }
    if rejection_products != BTreeSet::from([Product::Mac, Product::Ios]) {
        bail!("connectivity evidence requires one signed classic rejection per shipping responder");
    }
    Ok((success_pairs, success_sessions, rejection_products))
}

fn validate_capture_manifest(
    artifact_dir: &Path,
    product: Product,
    event_count: usize,
) -> Result<Option<Value>> {
    let path = artifact_dir.join(product.capture_file());
    let content = read_regular_file(&path, MAX_CAPTURE_BYTES)?;
    let payload: Value = serde_json::from_slice(&content)
        .with_context(|| format!("{} is not valid JSON", product.capture_file()))?;
    let object = payload
        .as_object()
        .ok_or_else(|| anyhow!("{} must be a JSON object", product.capture_file()))?;
    let mut expected_keys = BTreeSet::from([
        "schemaVersion",
        "profile",
        "captureMode",
        "processID",
        "processExecutable",
        "startTimeToken",
        "ownershipVerified",
        "candidateIdentityVerified",
        "candidateIdentityFile",
        "subsystem",
        "category",
        "eventCount",
    ]);
    if product == Product::Ios {
        expected_keys.extend([
            "bundleIdentifier",
            "iosReleaseArchive",
            "platform",
            "releaseArchiveBindingVerified",
        ]);
    }
    let actual_keys = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    if actual_keys != expected_keys {
        bail!("{} has an unexpected schema", product.capture_file());
    }
    require_json_value(object, "schemaVersion", &Value::from(1))?;
    require_json_value(object, "profile", &Value::from(CAPTURE_PROFILE))?;
    require_json_value(
        object,
        "captureMode",
        &Value::from(match product {
            Product::Mac => MAC_CAPTURE_MODE,
            Product::Ios => IOS_CAPTURE_MODE,
        }),
    )?;
    require_json_value(
        object,
        "processExecutable",
        &Value::from(match product {
            Product::Mac => MAC_PRODUCT,
            Product::Ios => IOS_EXECUTABLE,
        }),
    )?;
    require_json_value(object, "ownershipVerified", &Value::from(true))?;
    require_json_value(object, "candidateIdentityVerified", &Value::from(true))?;
    require_json_value(
        object,
        "candidateIdentityFile",
        &Value::from(match product {
            Product::Mac => "macos-release-candidate.json",
            Product::Ios => "release-acceptance.json",
        }),
    )?;
    require_json_value(object, "subsystem", &Value::from(SUBSYSTEM))?;
    require_json_value(object, "category", &Value::from(CATEGORY))?;
    require_json_value(object, "eventCount", &Value::from(event_count))?;
    let process_id = object
        .get("processID")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("capture processID must be an unsigned integer"))?;
    if process_id <= 1 {
        bail!("capture processID must be greater than one");
    }
    let start_time_token = object
        .get("startTimeToken")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("capture startTimeToken must be a string"))?;
    validate_start_time_token(start_time_token)?;
    if product == Product::Ios {
        require_json_value(
            object,
            "bundleIdentifier",
            &Value::from("com.skybridge.compass.ios"),
        )?;
        require_json_value(object, "platform", &Value::from("ios"))?;
        require_json_value(object, "releaseArchiveBindingVerified", &Value::from(true))?;
        validate_ios_archive_binding(
            object
                .get("iosReleaseArchive")
                .ok_or_else(|| anyhow!("iOS capture has no archive binding"))?,
        )?;
    }
    let mut canonical = serde_json::to_string_pretty(&payload)?;
    canonical.push('\n');
    if canonical.as_bytes() != content {
        bail!("{} must be canonical JSON", product.capture_file());
    }
    Ok(object.get("iosReleaseArchive").cloned())
}

fn validate_release_acceptance_binding(
    artifact_dir: &Path,
    expected_binding: &Value,
) -> Result<()> {
    let path = artifact_dir.join(RELEASE_ACCEPTANCE_FILE);
    let content = read_regular_file(&path, 2 * 1024 * 1024)?;
    let payload: Value =
        serde_json::from_slice(&content).context("release-acceptance.json is not valid JSON")?;
    if payload.get("iosReleaseArchive") != Some(expected_binding) {
        bail!("iOS product capture does not bind the release acceptance archive and IPA");
    }
    Ok(())
}

fn validate_ios_archive_binding(binding: &Value) -> Result<()> {
    let object = binding
        .as_object()
        .ok_or_else(|| anyhow!("iOS archive binding must be an object"))?;
    let expected_keys = BTreeSet::from([
        "schemaVersion",
        "identityPurpose",
        "archiveTreeSha256",
        "releaseTestingIpaSha256",
        "appExecutableUUIDs",
        "widgetExecutableUUIDs",
        "debugSymbolsVerified",
        "sourceInputDigest",
        "releaseVersion",
        "releaseBuild",
    ]);
    if object.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected_keys {
        bail!("iOS archive binding has an invalid field set");
    }
    require_json_value(object, "schemaVersion", &Value::from(1))?;
    require_json_value(
        object,
        "identityPurpose",
        &Value::from("detect-accidental-cross-run-mismatch"),
    )?;
    require_json_value(object, "debugSymbolsVerified", &Value::from(true))?;
    for key in [
        "archiveTreeSha256",
        "releaseTestingIpaSha256",
        "sourceInputDigest",
    ] {
        let value = object
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("iOS archive binding {key} must be text"))?;
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            bail!("iOS archive binding {key} is malformed");
        }
    }
    let release_version = object
        .get("releaseVersion")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("iOS archive binding releaseVersion must be text"))?;
    if !valid_semantic_version(release_version) {
        bail!("iOS archive binding releaseVersion is malformed");
    }
    let release_build = object
        .get("releaseBuild")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("iOS archive binding releaseBuild must be text"))?;
    if release_build.starts_with('0')
        || release_build.is_empty()
        || !release_build.bytes().all(|byte| byte.is_ascii_digit())
    {
        bail!("iOS archive binding releaseBuild is malformed");
    }
    for key in ["appExecutableUUIDs", "widgetExecutableUUIDs"] {
        validate_executable_uuids(
            object
                .get(key)
                .ok_or_else(|| anyhow!("iOS archive binding {key} is missing"))?,
            key,
        )?;
    }
    Ok(())
}

fn valid_semantic_version(value: &str) -> bool {
    let parts = value.split('.').collect::<Vec<_>>();
    parts.len() == 3
        && parts.iter().all(|part| {
            !part.is_empty()
                && part.bytes().all(|byte| byte.is_ascii_digit())
                && (part == &"0" || !part.starts_with('0'))
        })
}

fn validate_executable_uuids(value: &Value, label: &str) -> Result<()> {
    let records = value
        .as_array()
        .filter(|records| !records.is_empty())
        .ok_or_else(|| anyhow!("iOS archive binding {label} must be a non-empty array"))?;
    let mut normalized = Vec::new();
    for record in records {
        let object = record
            .as_object()
            .ok_or_else(|| anyhow!("iOS archive binding {label} record must be an object"))?;
        if object.keys().map(String::as_str).collect::<BTreeSet<_>>()
            != BTreeSet::from(["architecture", "uuid"])
        {
            bail!("iOS archive binding {label} record is malformed");
        }
        let architecture = object
            .get("architecture")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("iOS archive binding {label} architecture is invalid"))?;
        let uuid = object
            .get("uuid")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("iOS archive binding {label} uuid is invalid"))?;
        if architecture.is_empty()
            || !architecture
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
            || !valid_uuid(uuid)
        {
            bail!("iOS archive binding {label} record is invalid");
        }
        normalized.push((architecture, uuid));
    }
    if !normalized.windows(2).all(|pair| pair[0] < pair[1])
        || !normalized
            .iter()
            .any(|(architecture, _)| matches!(*architecture, "arm64" | "arm64e"))
    {
        bail!("iOS archive binding {label} must be sorted, unique, and contain 64-bit ARM");
    }
    Ok(())
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn require_json_value(object: &Map<String, Value>, key: &str, expected: &Value) -> Result<()> {
    if object.get(key) != Some(expected) {
        bail!("product evidence capture {key} mismatch");
    }
    Ok(())
}

fn validate_start_time_token(value: &str) -> Result<()> {
    let (seconds, micros) = value
        .split_once(':')
        .ok_or_else(|| anyhow!("capture startTimeToken is invalid"))?;
    if seconds.starts_with('0')
        || seconds.is_empty()
        || micros.is_empty()
        || !seconds.bytes().all(|byte| byte.is_ascii_digit())
        || !micros.bytes().all(|byte| byte.is_ascii_digit())
        || micros
            .parse::<u64>()
            .ok()
            .is_none_or(|value| value >= 1_000_000)
    {
        bail!("capture startTimeToken is invalid");
    }
    seconds
        .parse::<u64>()
        .context("capture startTimeToken seconds exceed u64")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OutputOptions;
    use crate::cli_test_support::{fixture_dir, make_test_dir};
    use std::path::PathBuf;

    fn args_for(artifact_dir: PathBuf) -> ConnectivityCheckArgs {
        ConnectivityCheckArgs {
            artifact_dir,
            output: OutputOptions { json: false },
        }
    }

    fn copy_fixture(name: &str) -> Result<PathBuf> {
        let source = fixture_dir(&["connectivity", "mac-ios-matrix-pass"]);
        let destination = make_test_dir(name)?;
        for file in [
            MAC_LOG_FILE,
            MAC_CAPTURE_FILE,
            IOS_LOG_FILE,
            IOS_CAPTURE_FILE,
            RELEASE_ACCEPTANCE_FILE,
        ] {
            fs::copy(source.join(file), destination.join(file))?;
        }
        Ok(destination)
    }

    fn mutate_file(dir: &Path, file: &str, old: &str, new: &str) -> Result<()> {
        let path = dir.join(file);
        let content = fs::read_to_string(&path)?;
        if !content.contains(old) {
            bail!("fixture mutation source was absent: {old}");
        }
        fs::write(path, content.replacen(old, new, 1))?;
        Ok(())
    }

    fn update_capture_event_count(dir: &Path, product: Product, event_count: usize) -> Result<()> {
        let path = dir.join(product.capture_file());
        let mut payload: Value = serde_json::from_slice(&fs::read(&path)?)?;
        payload["eventCount"] = Value::from(event_count);
        let mut canonical = serde_json::to_string_pretty(&payload)?;
        canonical.push('\n');
        fs::write(path, canonical)?;
        Ok(())
    }

    #[test]
    fn paired_shipping_product_matrix_passes() -> Result<()> {
        let report = build_connectivity_check_report(&args_for(fixture_dir(&[
            "connectivity",
            "mac-ios-matrix-pass",
        ])))?;
        assert!(report.checks.iter().all(|check| check.ok));
        assert_eq!(report.fault_stage, None);
        Ok(())
    }

    #[test]
    fn external_connectivity_case_labels_cannot_substitute_for_product_events() -> Result<()> {
        let dir = copy_fixture("connectivity-external-label")?;
        fs::write(
            dir.join(MAC_LOG_FILE),
            "connectivity-case id=mac-ios-xwing-xwing result=success\n",
        )?;
        let error = build_connectivity_check_report(&args_for(dir)).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("unsupported connectivity product event")
        );
        Ok(())
    }

    #[test]
    fn endpoint_join_rejects_role_session_suite_and_profile_drift() -> Result<()> {
        for mutation in ["role", "session", "suite", "profile"] {
            let dir = copy_fixture(&format!("connectivity-join-{mutation}"))?;
            let path = dir.join(IOS_LOG_FILE);
            let mut content = fs::read_to_string(&path)?;
            match mutation {
                "role" => {
                    for event in [
                        "connectivityAttemptStarted",
                        "connectivityAttemptAuthenticated",
                        "connectivityEndpoint",
                    ] {
                        let line = content
                            .lines()
                            .find(|line| {
                                line.starts_with(event)
                                    && line.contains(
                                        "attempt_ref=at1:22222222222222222222222222222222",
                                    )
                            })
                            .ok_or_else(|| anyhow!("role mutation target is absent"))?;
                        let replacement = line.replace(" role=responder ", " role=initiator ");
                        content = content.replacen(line, &replacement, 1);
                    }
                }
                "session" => {
                    content = content.replace(
                        "session_ref=ev1:22222222222222222222222222222222",
                        "session_ref=ev1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    );
                }
                "suite" => {
                    content = content.replacen("suite=ML-KEM-768", "suite=ML-KEM-768-FS", 1);
                }
                "profile" => {
                    content = content.replace(
                        "attempt_ref=at1:33333333333333333333333333333333 owner=SkyBridgeCompassiOS generation=13 role=initiator localProfile=xwing offeredProfiles=pqc+xwing requirePQC=1 allowClassicFallback=0 session_ref=ev1:33333333333333333333333333333333 attemptProfile=xwing",
                        "attempt_ref=at1:33333333333333333333333333333333 owner=SkyBridgeCompassiOS generation=13 role=initiator localProfile=xwing offeredProfiles=pqc+xwing requirePQC=1 allowClassicFallback=0 session_ref=ev1:33333333333333333333333333333333 attemptProfile=pqc",
                    );
                    content = content.replace(
                        "attempt_ref=at1:33333333333333333333333333333333 owner=SkyBridgeCompassiOS generation=13 role=initiator localProfile=xwing offeredProfiles=pqc+xwing attemptProfile=xwing suite=X-Wing",
                        "attempt_ref=at1:33333333333333333333333333333333 owner=SkyBridgeCompassiOS generation=13 role=initiator localProfile=xwing offeredProfiles=pqc+xwing attemptProfile=pqc suite=ML-KEM-768",
                    );
                }
                _ => unreachable!(),
            }
            fs::write(path, content)?;
            let error = build_connectivity_check_report(&args_for(dir)).unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("paired connectivity endpoints disagree")
            );
        }
        Ok(())
    }

    #[test]
    fn local_generation_and_actual_offer_must_remain_consistent() -> Result<()> {
        let generation_dir = copy_fixture("connectivity-generation")?;
        mutate_file(
            &generation_dir,
            MAC_LOG_FILE,
            "generation=2 role=initiator localProfile=xwing",
            "generation=9 role=initiator localProfile=xwing",
        )?;
        let error = build_connectivity_check_report(&args_for(generation_dir)).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("connectivity attempt changes locally owned fields")
        );

        let generation_reuse_dir = copy_fixture("connectivity-generation-reuse")?;
        let path = generation_reuse_dir.join(MAC_LOG_FILE);
        let content = fs::read_to_string(&path)?;
        let target_attempt = "attempt_ref=at1:22222222222222222222222222222222";
        let mut mutation_count = 0;
        let mutated = content
            .lines()
            .map(|line| {
                if line.contains(target_attempt) && line.contains("generation=2 role=") {
                    mutation_count += 1;
                    line.replace("generation=2 role=", "generation=1 role=")
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        assert_eq!(mutation_count, 3);
        fs::write(path, mutated)?;
        let error = build_connectivity_check_report(&args_for(generation_reuse_dir)).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("reuses one local generation across attempts")
        );

        let offer_dir = copy_fixture("connectivity-offer")?;
        let path = offer_dir.join(MAC_LOG_FILE);
        let content = fs::read_to_string(&path)?;
        let target_attempt = "attempt_ref=at1:33333333333333333333333333333333";
        let mut mutation_count = 0;
        let mutated = content
            .lines()
            .map(|line| {
                if line.contains(target_attempt) && line.contains("offeredProfiles=pqc+xwing") {
                    mutation_count += 1;
                    line.replace("offeredProfiles=pqc+xwing", "offeredProfiles=pqc")
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        assert_eq!(mutation_count, 3);
        fs::write(path, mutated)?;
        let error = build_connectivity_check_report(&args_for(offer_dir)).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("negotiated suite family was absent from the actual local offer")
        );
        Ok(())
    }

    #[test]
    fn classic_edges_require_verified_shipping_responder_rejections() -> Result<()> {
        let signature_dir = copy_fixture("connectivity-signature")?;
        mutate_file(
            &signature_dir,
            MAC_LOG_FILE,
            "peerOfferSignature=verified",
            "peerOfferSignature=claimed",
        )?;
        assert!(build_connectivity_check_report(&args_for(signature_dir)).is_err());

        let missing_dir = copy_fixture("connectivity-missing-rejection")?;
        let path = missing_dir.join(IOS_LOG_FILE);
        let content = fs::read_to_string(&path)?;
        let filtered = content
            .lines()
            .filter(|line| !line.contains("at1:55555555555555555555555555555555"))
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        fs::write(path, filtered)?;
        update_capture_event_count(&missing_dir, Product::Ios, 9)?;
        let error = build_connectivity_check_report(&args_for(missing_dir)).unwrap_err();
        assert!(error.to_string().contains("one signed classic rejection"));
        Ok(())
    }

    #[test]
    fn exact_ios_candidate_capture_is_mandatory_and_cannot_be_simulator_or_helper() -> Result<()> {
        let missing_dir = copy_fixture("connectivity-missing-ios-capture")?;
        fs::remove_file(missing_dir.join(IOS_CAPTURE_FILE))?;
        assert!(build_connectivity_check_report(&args_for(missing_dir)).is_err());

        for (index, (old, new)) in [
            ("\"platform\": \"ios\"", "\"platform\": \"simulator\""),
            (
                "\"processExecutable\": \"SkyBridgeCompass-iOS\"",
                "\"processExecutable\": \"LocalLanInteropHost\"",
            ),
            (
                "\"releaseArchiveBindingVerified\": true",
                "\"releaseArchiveBindingVerified\": false",
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let dir = copy_fixture(&format!("connectivity-ios-binding-{index}"))?;
            mutate_file(&dir, IOS_CAPTURE_FILE, old, new)?;
            assert!(build_connectivity_check_report(&args_for(dir)).is_err());
        }
        Ok(())
    }

    #[test]
    fn decode_only_qperiapt_suite_is_not_formal_connectivity_evidence() -> Result<()> {
        let dir = copy_fixture("connectivity-decode-only-suite")?;
        for file in [MAC_LOG_FILE, IOS_LOG_FILE] {
            mutate_file(
                &dir,
                file,
                "suite=ML-KEM-768",
                "suite=Q-Periapt-ContextBound",
            )?;
        }
        let error = build_connectivity_check_report(&args_for(dir)).unwrap_err();
        assert!(error.to_string().contains("invalid connectivity terminal"));
        Ok(())
    }

    #[test]
    fn connectivity_attempt_retains_twenty_event_hard_limit() -> Result<()> {
        let dir = copy_fixture("connectivity-event-limit")?;
        let path = dir.join(MAC_LOG_FILE);
        let content = fs::read_to_string(&path)?;
        let started = content
            .lines()
            .next()
            .ok_or_else(|| anyhow!("fixture is empty"))?;
        let oversized = std::iter::repeat_n(started, MAX_EVENTS_PER_ATTEMPT + 1)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        fs::write(path, oversized)?;
        update_capture_event_count(&dir, Product::Mac, MAX_EVENTS_PER_ATTEMPT + 1)?;
        let error = build_connectivity_check_report(&args_for(dir)).unwrap_err();
        assert!(error.to_string().contains("fixed 20-event product limit"));
        Ok(())
    }

    #[test]
    fn evidence_files_reject_links_and_path_replacement() -> Result<()> {
        let hard_link_dir = copy_fixture("connectivity-hard-link")?;
        let log_path = hard_link_dir.join(MAC_LOG_FILE);
        let backing_path = hard_link_dir.join("mac-product-session.backing.log");
        fs::rename(&log_path, &backing_path)?;
        fs::hard_link(&backing_path, &log_path)?;
        let error = build_connectivity_check_report(&args_for(hard_link_dir)).unwrap_err();
        assert!(error.to_string().contains("single-link regular file"));

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            let symlink_dir = copy_fixture("connectivity-symlink")?;
            let log_path = symlink_dir.join(MAC_LOG_FILE);
            fs::remove_file(&log_path)?;
            symlink(IOS_LOG_FILE, &log_path)?;
            let error = build_connectivity_check_report(&args_for(symlink_dir)).unwrap_err();
            assert!(error.to_string().contains("single-link regular file"));

            let replacement_dir = make_test_dir("connectivity-path-replacement")?;
            let evidence_path = replacement_dir.join("evidence.log");
            let replacement_path = replacement_dir.join("replacement.log");
            fs::write(&evidence_path, b"original\n")?;
            fs::write(&replacement_path, b"replaced\n")?;
            let original_metadata = fs::symlink_metadata(&evidence_path)?;
            fs::rename(&replacement_path, &evidence_path)?;
            let opened = open_evidence_file_no_follow(&evidence_path)?;
            let error =
                read_opened_regular_file(&evidence_path, MAX_LOG_BYTES, &original_metadata, opened)
                    .unwrap_err();
            assert!(error.to_string().contains("changed before it was opened"));
        }
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn connectivity_artifact_directory_must_not_be_a_symlink() -> Result<()> {
        use std::os::unix::fs::symlink;

        let source = fixture_dir(&["connectivity", "mac-ios-matrix-pass"]);
        let parent = make_test_dir("connectivity-directory-symlink")?;
        let linked = parent.join("artifact");
        symlink(source, &linked)?;
        let error = build_connectivity_check_report(&args_for(linked)).unwrap_err();
        assert!(error.to_string().contains("must be a real directory"));
        Ok(())
    }
}
