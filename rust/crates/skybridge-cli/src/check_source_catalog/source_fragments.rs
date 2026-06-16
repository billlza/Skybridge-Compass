mod catalog;
mod check_coverage;
mod core_cli;
mod integration_tests;
mod p2p_remote;
mod performance_tests;
mod release;
mod smoke_suite;
mod webrtc_media;
mod webrtc_media_doctor;
mod webrtc_media_doctor_tests;

const CLI_RUST_SOURCE_FRAGMENT_GROUPS: &[&[(&str, &str)]] = &[
    core_cli::SOURCE_FRAGMENTS,
    check_coverage::SOURCE_FRAGMENTS,
    p2p_remote::SOURCE_FRAGMENTS,
    performance_tests::SOURCE_FRAGMENTS,
    smoke_suite::SOURCE_FRAGMENTS,
    webrtc_media::SOURCE_FRAGMENTS,
    webrtc_media_doctor::SOURCE_FRAGMENTS,
    webrtc_media_doctor_tests::SOURCE_FRAGMENTS,
    catalog::SOURCE_FRAGMENTS,
];

pub(super) fn cli_rust_source_fragments() -> impl Iterator<Item = (&'static str, &'static str)> {
    CLI_RUST_SOURCE_FRAGMENT_GROUPS
        .iter()
        .flat_map(|group| group.iter().copied())
}

pub(super) fn check_coverage_evidence_fragments()
-> impl Iterator<Item = (&'static str, &'static str)> {
    release::SOURCE_FRAGMENTS
        .iter()
        .chain(integration_tests::SOURCE_FRAGMENTS.iter())
        .copied()
}
