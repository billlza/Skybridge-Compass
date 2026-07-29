# Formal Composition Boundary

Status: **design only**. Existing SkyBridge and Q-Periapt proofs are upstream
component evidence. Their conclusions do not compose automatically.

## Responsibilities

| Layer | Intended method | What it may support | What it does not support |
|---|---|---|---|
| Hybrid combiner | EasyCrypt | Canonical encoder injectivity; ContextBound commitment/binding under stated assumptions; field-separation results | AKE authentication, downgrade behavior, session ownership, ABI behavior, constant time, or code refinement |
| Network protocol | New Tamarin theory | Active-network secrecy and agreement on the peer-visible decision projection, purpose, context, transcript, and Finished; explicit compromise cases; no policy-bound business fallback | Equality of heterogeneous local providers, Swift/Rust scheduling, crash recovery, bounded resources, durable storage, or source-to-code correspondence |
| Independent symbolic cross-check | New ProVerif model | A simplified check of secrecy and correspondence over the same normative message grammar | Stateful CAS, cooldown, incarnation replacement, crash semantics, or independent computational validation |
| State and commit protocol | TLA+/PlusCal, Ivy, or an equivalently explicit state model | CAS, crash/restart, ABA/session replacement, bilateral readiness, exact-owner publication, effect journaling, and policy-update semantics | Cryptographic reductions or production scheduler behavior without a code link |
| Implementation conformance | Canonical vectors, differential tests, fuzzing, sanitizers, traceability map | Evidence that implementations follow selected encodings, state transitions, and trusted-effect boundaries | A mechanized refinement theorem or malicious-builder resistance |
| Final binary and devices | Source-bound build, binary identity, physical-device and network evidence | Execution of the final candidate in named environments | Universal portability, remote attestation, or security outside the measured environments |

## Required interface invariants

The paper may combine component results only after the following interfaces are
defined in one normative specification and represented consistently in the
models and implementation:

1. Exact creation rule from an authenticated policy snapshot, local caller,
   expected peer, purpose, and owner to each endpoint's
   `LocalAuthenticatedDecision`.
2. Exact peer-visible projection from each local decision and `PurposeV1` to
   `wireDecisionDigest` and `BoundSessionContextV1`; local provider and owner
   identities are not compared across peers.
3. Exact projection from pre-KEM context, Message A, Message B, and Finished to
   the key schedule and transcript digest.
4. Exact rule by which each local decision authorizes one local provider and
   exact purpose and forbids all later re-selection.
5. Exact separation between peer-agreed `peerSessionId` and each endpoint's
   private `LocalOwnerBinding`, including the final transactional owner CAS.
6. Exact authorization record and recoverable transaction that precede grant
   publication; this record is not an application-success receipt.
7. Exact receipt grammar, purpose-separated authentication, replay/idempotency
   rules, and application-effect correspondence.
8. Exact relationship between a compatibility attempt declaration and any
   classic-capable protocol identity.
9. Exact derivation of `sharedGrantId`, both authenticated `GrantReadyV1`
   values, and the role-ordered `bilateralReadyDigest`; endpoint-private grant,
   decision, commit, and owner identifiers are never compared across peers.
10. Exact authority of each `TrustedEffectCommitter`, including which concrete
    platform completion event it can report and why an untrusted application
    cannot mint a successful effect outcome.
11. Exact endpoint-private `LocalEffectScopeSet` and opaque grant-handle rules;
    local policy-store IDs, providers, owners, effect targets, decision epochs,
    and grant/commit IDs cannot cross the wire or application serialization
    boundary.

## Minimum theorem set

At its symbolic interface, the integrated Tamarin model should include:

- reachability for each supported honest path;
- an explicit witness for any intentionally absent forward-secrecy property;
- injective agreement on peers, managed policy identity, wire cryptographic
  profile, purpose, pre-KEM context, transcript, session key, and
  `peerSessionId`; this theorem does not assert equality of local provider
  identities or local owner generations;
- abstract authorization events for the exact peer and purpose by each
  endpoint's local decision, including the selected provider-class label;
- session-key secrecy with explicit identity, KEM, component, and ephemeral
  compromise conditions;
- no policy-bound business-capable classic acceptance;
- no local grant publication before mutual Finished, exact local-owner
  transaction, matching authorization record, and bilateral ready agreement;
- no cross-purpose key or grant use;
- receipt authentication over the shared grant and bilateral-ready values, plus
  correspondence to the exact purpose-specific trusted effect event;
- replay and stale `peerSessionId`, local owner, decision epoch, handle, and
  receipt-sequence rejection;
- authenticated and correctly classified compatibility declarations.

The real local provider's refinement to the agreed wire profile is a distinct
conformance and runtime obligation. Tamarin may relate abstract decision and
provider events, but it cannot discharge that implementation obligation.

The state model should include:

- concurrent policy update and equal-version equivocation;
- crash before and after monotonic CAS;
- crash before, during, and after the combined owner/grant/authorization-record
  transaction, plus recovery to reissue or revoke without inventing an
  application success;
- loss, duplication, reordering, conflict, timeout, and crash around each
  `GrantReadyV1`, durable ready-outbox write, bilateral enable transition, and
  local owner revalidation;
- monotonic readiness product states, bounded early-peer-ready storage, and
  authenticated abort/revoke with local expiry and one-sided activation;
- endpoint-local causality from authorization to ready send, peer-ready receipt
  to final owner CAS and enable, and local enable to effect; no distributed
  atomic-enable or global-clock premise;
- crash before an effect, after an external effect but before journal commit,
  and after journal commit but before receipt transmission, including
  `Reserved`, `MayHaveStarted`, `Committed`, `Rejected`, and `Ambiguous`;
- owner replacement during every asynchronous boundary;
- policy update while a session is pending or active;
- bounded transition-history exhaustion and explicit re-enrollment;
- handle expiry, revocation, caller-principal change, and operation-id replay.

## Claim language

Until a computational AKE proof and mechanized implementation refinement exist,
the strongest accurate combined formulation is:

> A component-level computational binding theorem and a machine-checked
> symbolic protocol model establish complementary properties under their
> stated abstractions; canonical encodings, conformance tests, and source-bound
> execution evidence link selected implementation boundaries.

The manuscript must not replace this with any of the following:

- “end-to-end computational proof”;
- “formally verified implementation”;
- “two independent provers prove the binary”;
- “artifact provenance proves runtime behavior.”

## Evidence root

All final formal sources, reports, negative controls, code, generated bindings,
binaries, device runs, raw measurements, and paper tables must be selected by a
single immutable evidence manifest. Historical component artifacts remain named
upstream inputs; they cannot be copied into the new ledger as `passed` evidence.
