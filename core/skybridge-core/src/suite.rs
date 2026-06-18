/// Canonical SkyBridge crypto suite wire IDs from the transport matrix ADR.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CryptoSuite {
    XWingHybrid,
    MlKem768MlDsa65,
    X25519Ed25519,
    P256Ecdsa,
}

impl CryptoSuite {
    pub const fn wire_id(self) -> u16 {
        match self {
            Self::XWingHybrid => 0x0001,
            Self::MlKem768MlDsa65 => 0x0101,
            Self::X25519Ed25519 => 0x1001,
            Self::P256Ecdsa => 0x1002,
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::XWingHybrid => "x-wing-hybrid",
            Self::MlKem768MlDsa65 => "ml-kem-768-ml-dsa-65",
            Self::X25519Ed25519 => "x25519-ed25519",
            Self::P256Ecdsa => "p256-ecdsa",
        }
    }

    pub const fn from_wire_id(id: u16) -> Option<Self> {
        match id {
            0x0001 => Some(Self::XWingHybrid),
            0x0101 => Some(Self::MlKem768MlDsa65),
            0x1001 => Some(Self::X25519Ed25519),
            0x1002 => Some(Self::P256Ecdsa),
            _ => None,
        }
    }

    pub const fn is_classic(self) -> bool {
        matches!(self, Self::X25519Ed25519 | Self::P256Ecdsa)
    }
}

const SUITE_PRIORITY: [CryptoSuite; 4] = [
    CryptoSuite::XWingHybrid,
    CryptoSuite::MlKem768MlDsa65,
    CryptoSuite::X25519Ed25519,
    CryptoSuite::P256Ecdsa,
];

/// Runtime provider facts. Offered suites must be derived from these facts,
/// not from a static desired list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CryptoProviderCapabilities {
    pub supports_xwing_hybrid: bool,
    pub supports_mlkem_768_mldsa_65: bool,
    pub supports_x25519_ed25519: bool,
    pub supports_p256_ecdsa: bool,
}

impl CryptoProviderCapabilities {
    pub const fn empty() -> Self {
        Self {
            supports_xwing_hybrid: false,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: false,
            supports_p256_ecdsa: false,
        }
    }

    pub const fn research_all() -> Self {
        Self {
            supports_xwing_hybrid: true,
            supports_mlkem_768_mldsa_65: true,
            supports_x25519_ed25519: true,
            supports_p256_ecdsa: true,
        }
    }

    pub const fn current_p256() -> Self {
        Self {
            supports_xwing_hybrid: false,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: false,
            supports_p256_ecdsa: true,
        }
    }

    /// Capabilities actually backed by compiled-in providers: real X-Wing and
    /// ML-KEM-768/ML-DSA-65 post-quantum KEMs (see [`crate::pqc`]) plus the
    /// classic P-256 ECDH path (see [`crate::crypto`]). The `X25519Ed25519`
    /// suite is intentionally false until that classic provider is wired.
    pub const fn with_native_pqc() -> Self {
        Self {
            supports_xwing_hybrid: true,
            supports_mlkem_768_mldsa_65: true,
            supports_x25519_ed25519: false,
            supports_p256_ecdsa: true,
        }
    }

    pub fn supports(self, suite: CryptoSuite) -> bool {
        match suite {
            CryptoSuite::XWingHybrid => self.supports_xwing_hybrid,
            CryptoSuite::MlKem768MlDsa65 => self.supports_mlkem_768_mldsa_65,
            CryptoSuite::X25519Ed25519 => self.supports_x25519_ed25519,
            CryptoSuite::P256Ecdsa => self.supports_p256_ecdsa,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CryptoSuitePolicy {
    pub allow_classic_fallback: bool,
    pub allow_legacy_p256: bool,
    pub timeout_observed: bool,
}

impl CryptoSuitePolicy {
    pub const fn strict_pqc() -> Self {
        Self {
            allow_classic_fallback: false,
            allow_legacy_p256: false,
            timeout_observed: false,
        }
    }

    pub const fn compatibility() -> Self {
        Self {
            allow_classic_fallback: true,
            allow_legacy_p256: false,
            timeout_observed: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CryptoSuiteAudit {
    HybridPqcPreferred,
    PurePqcPreferred,
    ClassicPolicyFallback,
    LegacyPolicyFallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CryptoSuiteSelectionError {
    UnknownSuiteId(u16),
    NoMutualSuite,
    TimeoutCannotDowngrade,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectedCryptoSuite {
    pub suite: CryptoSuite,
    pub audit: CryptoSuiteAudit,
}

pub fn offered_suites(
    caps: CryptoProviderCapabilities,
    policy: CryptoSuitePolicy,
) -> Vec<CryptoSuite> {
    SUITE_PRIORITY
        .into_iter()
        .filter(|suite| caps.supports(*suite))
        .filter(|suite| match suite {
            CryptoSuite::XWingHybrid | CryptoSuite::MlKem768MlDsa65 => true,
            CryptoSuite::X25519Ed25519 => policy.allow_classic_fallback,
            CryptoSuite::P256Ecdsa => policy.allow_classic_fallback && policy.allow_legacy_p256,
        })
        .collect()
}

pub fn parse_wire_suite_ids(ids: &[u16]) -> Result<Vec<CryptoSuite>, CryptoSuiteSelectionError> {
    ids.iter()
        .map(|id| {
            CryptoSuite::from_wire_id(*id).ok_or(CryptoSuiteSelectionError::UnknownSuiteId(*id))
        })
        .collect()
}

pub fn negotiate_suite(
    local: CryptoProviderCapabilities,
    remote_wire_ids: &[u16],
    policy: CryptoSuitePolicy,
) -> Result<SelectedCryptoSuite, CryptoSuiteSelectionError> {
    let remote = parse_wire_suite_ids(remote_wire_ids)?;
    let local_offered = offered_suites(local, policy);

    for suite in SUITE_PRIORITY {
        if local_offered.contains(&suite) && remote.contains(&suite) {
            if suite.is_classic() && policy.timeout_observed {
                return Err(CryptoSuiteSelectionError::TimeoutCannotDowngrade);
            }

            return Ok(SelectedCryptoSuite {
                suite,
                audit: audit_for_suite(suite),
            });
        }
    }

    if policy.timeout_observed
        && local_offered.iter().any(|suite| suite.is_classic())
        && remote.iter().any(|suite| suite.is_classic())
    {
        return Err(CryptoSuiteSelectionError::TimeoutCannotDowngrade);
    }

    Err(CryptoSuiteSelectionError::NoMutualSuite)
}

fn audit_for_suite(suite: CryptoSuite) -> CryptoSuiteAudit {
    match suite {
        CryptoSuite::XWingHybrid => CryptoSuiteAudit::HybridPqcPreferred,
        CryptoSuite::MlKem768MlDsa65 => CryptoSuiteAudit::PurePqcPreferred,
        CryptoSuite::X25519Ed25519 => CryptoSuiteAudit::ClassicPolicyFallback,
        CryptoSuite::P256Ecdsa => CryptoSuiteAudit::LegacyPolicyFallback,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offered_suites_are_derived_from_provider_support() {
        let caps = CryptoProviderCapabilities {
            supports_xwing_hybrid: true,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: true,
            supports_p256_ecdsa: true,
        };

        assert_eq!(
            offered_suites(caps, CryptoSuitePolicy::strict_pqc()),
            vec![CryptoSuite::XWingHybrid]
        );
        assert_eq!(
            offered_suites(caps, CryptoSuitePolicy::compatibility()),
            vec![CryptoSuite::XWingHybrid, CryptoSuite::X25519Ed25519]
        );
    }

    #[test]
    fn negotiation_prefers_hybrid_then_pure_pqc() {
        let selected = negotiate_suite(
            CryptoProviderCapabilities::research_all(),
            &[
                CryptoSuite::X25519Ed25519.wire_id(),
                CryptoSuite::MlKem768MlDsa65.wire_id(),
                CryptoSuite::XWingHybrid.wire_id(),
            ],
            CryptoSuitePolicy::compatibility(),
        )
        .expect("suite");

        assert_eq!(selected.suite, CryptoSuite::XWingHybrid);
        assert_eq!(selected.audit, CryptoSuiteAudit::HybridPqcPreferred);
    }

    #[test]
    fn classic_fallback_requires_policy_gate() {
        let caps = CryptoProviderCapabilities {
            supports_xwing_hybrid: false,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: true,
            supports_p256_ecdsa: false,
        };

        let strict = negotiate_suite(
            caps,
            &[CryptoSuite::X25519Ed25519.wire_id()],
            CryptoSuitePolicy::strict_pqc(),
        );
        assert_eq!(strict, Err(CryptoSuiteSelectionError::NoMutualSuite));

        let selected = negotiate_suite(
            caps,
            &[CryptoSuite::X25519Ed25519.wire_id()],
            CryptoSuitePolicy::compatibility(),
        )
        .expect("classic fallback");
        assert_eq!(selected.suite, CryptoSuite::X25519Ed25519);
        assert_eq!(selected.audit, CryptoSuiteAudit::ClassicPolicyFallback);
    }

    #[test]
    fn timeout_never_triggers_crypto_downgrade() {
        let caps = CryptoProviderCapabilities {
            supports_xwing_hybrid: false,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: true,
            supports_p256_ecdsa: false,
        };
        let policy = CryptoSuitePolicy {
            timeout_observed: true,
            ..CryptoSuitePolicy::compatibility()
        };

        let result = negotiate_suite(caps, &[CryptoSuite::X25519Ed25519.wire_id()], policy);

        assert_eq!(
            result,
            Err(CryptoSuiteSelectionError::TimeoutCannotDowngrade)
        );
    }

    #[test]
    fn unknown_suite_ids_are_rejected_safely() {
        let result = negotiate_suite(
            CryptoProviderCapabilities::research_all(),
            &[0xBEEF],
            CryptoSuitePolicy::compatibility(),
        );

        assert_eq!(
            result,
            Err(CryptoSuiteSelectionError::UnknownSuiteId(0xBEEF))
        );
    }

    #[test]
    fn legacy_p256_requires_explicit_policy() {
        let strict = offered_suites(
            CryptoProviderCapabilities::current_p256(),
            CryptoSuitePolicy::compatibility(),
        );
        assert!(strict.is_empty());

        let policy = CryptoSuitePolicy {
            allow_legacy_p256: true,
            ..CryptoSuitePolicy::compatibility()
        };
        assert_eq!(
            offered_suites(CryptoProviderCapabilities::current_p256(), policy),
            vec![CryptoSuite::P256Ecdsa]
        );
    }
}
