"""Canonical test fixtures for paired shipping-product connectivity evidence."""

from __future__ import annotations


MAC_PRODUCT = "SkyBridgeCompassApp"
IOS_PRODUCT = "SkyBridgeCompassiOS"


def golden_ios_archive_binding() -> dict[str, object]:
    """Return a valid non-secret exact-binding shape for consumer fixtures."""

    return {
        "schemaVersion": 1,
        "identityPurpose": "detect-accidental-cross-run-mismatch",
        "archiveTreeSha256": "3" * 64,
        "releaseTestingIpaSha256": "4" * 64,
        "appExecutableUUIDs": [
            {
                "architecture": "arm64",
                "uuid": "11111111-1111-1111-1111-111111111111",
            }
        ],
        "widgetExecutableUUIDs": [
            {
                "architecture": "arm64",
                "uuid": "22222222-2222-2222-2222-222222222222",
            }
        ],
        "debugSymbolsVerified": True,
        "sourceInputDigest": "2" * 64,
        "releaseVersion": "1.2.3",
        "releaseBuild": "42",
    }


def _attempt_fields(
    *,
    owner: str,
    attempt_ref: str,
    generation: int,
    role: str,
    local_profile: str,
    offered_profiles: str,
) -> str:
    return (
        f"transport=p2p attempt_ref={attempt_ref} owner={owner} "
        f"generation={generation} role={role} localProfile={local_profile} "
        f"offeredProfiles={offered_profiles} requirePQC=1 allowClassicFallback=0"
    )


def _success_lines(
    *,
    owner: str,
    attempt_byte: str,
    session_byte: str,
    generation: int,
    role: str,
    local_profile: str,
    offered_profiles: str,
    attempt_profile: str,
    suite: str,
) -> list[str]:
    attempt_ref = "at1:" + attempt_byte * 32
    session_ref = "ev1:" + session_byte * 32
    common = _attempt_fields(
        owner=owner,
        attempt_ref=attempt_ref,
        generation=generation,
        role=role,
        local_profile=local_profile,
        offered_profiles=offered_profiles,
    )
    endpoint_common = (
        f"transport=p2p session_ref={session_ref} attempt_ref={attempt_ref} "
        f"owner={owner} generation={generation} role={role} "
        f"localProfile={local_profile} offeredProfiles={offered_profiles}"
    )
    return [
        f"connectivityAttemptStarted {common} result=started",
        f"connectivityAttemptAuthenticated {common} session_ref={session_ref} "
        f"attemptProfile={attempt_profile} result=authenticated",
        f"connectivityEndpoint {endpoint_common} attemptProfile={attempt_profile} "
        f"suite={suite} requirePQC=1 allowClassicFallback=0 result=success",
    ]


def _rejection_lines(
    *,
    owner: str,
    attempt_byte: str,
    generation: int,
    local_profile: str,
    offered_profiles: str,
) -> list[str]:
    common = _attempt_fields(
        owner=owner,
        attempt_ref="at1:" + attempt_byte * 32,
        generation=generation,
        role="responder",
        local_profile=local_profile,
        offered_profiles=offered_profiles,
    )
    return [
        f"connectivityAttemptStarted {common} result=started",
        f"connectivityPolicyRejected {common} peerOfferedProfiles=classic "
        "peerOfferSignature=verified reason=strict-pqc-rejects-classic result=rejected",
    ]


def connectivity_product_logs() -> tuple[list[str], list[str]]:
    """Return the exact three-success/two-rejection Mac+iOS product matrix."""

    mac_lines: list[str] = []
    ios_lines: list[str] = []
    success_specs = (
        # Mac profile, iOS profile, suite family, and Mac role. The mixed
        # profile pairs intentionally negotiate different allowed families.
        ("1", "1", "xwing", "xwing", "xwing", "X-Wing", "initiator"),
        ("2", "2", "xwing", "pqc", "pqc", "ML-KEM-768", "initiator"),
        ("3", "3", "pqc", "xwing", "xwing", "X-Wing", "responder"),
    )
    for index, (
        attempt_byte,
        session_byte,
        mac_profile,
        ios_profile,
        attempt_profile,
        suite,
        mac_role,
    ) in enumerate(success_specs, 1):
        mac_lines.extend(_success_lines(
            owner=MAC_PRODUCT,
            attempt_byte=attempt_byte,
            session_byte=session_byte,
            generation=index,
            role=mac_role,
            local_profile=mac_profile,
            offered_profiles="pqc+xwing",
            attempt_profile=attempt_profile,
            suite=suite,
        ))
        ios_lines.extend(_success_lines(
            owner=IOS_PRODUCT,
            attempt_byte=attempt_byte,
            session_byte=session_byte,
            generation=index + 10,
            role="responder" if mac_role == "initiator" else "initiator",
            local_profile=ios_profile,
            offered_profiles="pqc" if ios_profile == "pqc" else "pqc+xwing",
            attempt_profile=attempt_profile,
            suite=suite,
        ))
    mac_lines.extend(_rejection_lines(
        owner=MAC_PRODUCT,
        attempt_byte="4",
        generation=4,
        local_profile="pqc",
        offered_profiles="pqc+xwing",
    ))
    ios_lines.extend(_rejection_lines(
        owner=IOS_PRODUCT,
        attempt_byte="5",
        generation=14,
        local_profile="xwing",
        offered_profiles="pqc+xwing",
    ))
    return mac_lines, ios_lines


def capture_manifest(
    owner: str,
    event_count: int,
    process_id: int,
    *,
    ios_release_archive: dict[str, object] | None = None,
) -> dict[str, object]:
    """Return the exact public capture manifest for one shipping product log."""

    if owner == MAC_PRODUCT:
        return {
            "schemaVersion": 1,
            "profile": "skybridge-product-release-evidence-capture",
            "captureMode": "unified-log-process-bound",
            "processID": process_id,
            "processExecutable": owner,
            "startTimeToken": "1700000000:123456",
            "ownershipVerified": True,
            "candidateIdentityVerified": True,
            "candidateIdentityFile": "macos-release-candidate.json",
            "subsystem": "com.skybridge.compass.release-evidence",
            "category": "ProductSession",
            "eventCount": event_count,
        }
    if owner == IOS_PRODUCT:
        if ios_release_archive is None:
            ios_release_archive = golden_ios_archive_binding()
        return {
            "schemaVersion": 1,
            "profile": "skybridge-product-release-evidence-capture",
            "captureMode": "devicectl-unified-log-process-bound",
            "platform": "ios",
            "processID": process_id,
            "processExecutable": "SkyBridgeCompass-iOS",
            "bundleIdentifier": "com.skybridge.compass.ios",
            "startTimeToken": "1700000000:223456",
            "ownershipVerified": True,
            "candidateIdentityVerified": True,
            "candidateIdentityFile": "release-acceptance.json",
            "releaseArchiveBindingVerified": True,
            "iosReleaseArchive": ios_release_archive,
            "subsystem": "com.skybridge.compass.release-evidence",
            "category": "ProductSession",
            "eventCount": event_count,
        }
    raise ValueError(f"unsupported product evidence owner: {owner}")
