use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "signaling_doctor_gate",
        domain: "control-plane",
        command: "skybridge doctor signaling",
        covered: source_has_all(
            source,
            &[
                "Signaling(SignalingDoctorArgs)",
                "Some(DoctorSubcommand::Signaling(signaling))",
                "doctor_signaling",
                "build_signaling_doctor_report",
            ],
        ),
        evidence:
            "signaling doctor parses, dispatches, and builds a structured control-plane report"
                .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "media_lease_doctor_gate",
        domain: "control-plane",
        command: "skybridge doctor media-lease",
        covered: source_has_all(
            source,
            &[
                "MediaLease(MediaLeaseDoctorArgs)",
                "Some(DoctorSubcommand::MediaLease(media_lease))",
                "doctor_media_lease",
                "build_media_lease_doctor_report",
            ],
        ),
        evidence:
            "media lease doctor parses, dispatches, and builds a structured control-plane report"
                .to_owned(),
    });
}
