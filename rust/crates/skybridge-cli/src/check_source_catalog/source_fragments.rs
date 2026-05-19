mod catalog;
mod check_coverage;
mod core_cli;
mod p2p_remote;
mod performance_tests;
mod smoke_suite;
mod webrtc_media;
mod webrtc_media_doctor;
mod webrtc_media_doctor_tests;

const SOURCE_FRAGMENT_GROUPS: &[&[(&str, &str)]] = &[
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

pub(super) fn cli_check_coverage_source_fragments()
-> impl Iterator<Item = (&'static str, &'static str)> {
    SOURCE_FRAGMENT_GROUPS
        .iter()
        .flat_map(|group| group.iter().copied())
}
