/// Pairing-code PAKE is intentionally unavailable in this major release.
///
/// The removed implementation used a hash construction in place of the group
/// operations required by RFC 9382 SPAKE2+. Keeping that implementation under a
/// PAKE name would permit offline enumeration of the six-digit pairing code.
/// Reintroduction requires a reviewed RFC 9382 SPAKE2+ or OPAQUE implementation,
/// interoperable vectors, transcript binding, and physical-device evidence.
@available(
    *,
    unavailable,
    message: "Pairing-code PAKE is disabled until an audited standards-compliant implementation is available"
)
public actor PAKEService {}
