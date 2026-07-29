# BoundSessionV1 Design Contract

Status: **design only**. This file defines the intended research object; it is
not evidence that the protocol is implemented or secure.

## 1. Authority and dependency direction

The protocol has one authoritative local decision path on each endpoint:

```text
signed policy + monotonic state
    -> AuthenticatedPolicySnapshot

AuthenticatedPolicySnapshot
  + authenticated local caller principal
  + expected peer
  + exact PurposeV1
  + exact LocalOwnerBinding
  + runtime capabilities
    -> LocalAuthenticatedDecision
    -> BoundSessionV1 handshake
    -> local authorization commit
    -> bilateral GrantReadyV1 set
    -> local BoundSessionGrant publication
    -> one trusted purpose-specific effect path
```

Application adapters depend on the protocol core. The protocol core depends on
narrow ports for policy verification, hybrid KEM operations, identity signing,
transport, monotonic storage, authorization commit, diagnostic audit, and time.
Purpose-specific success also crosses a narrow `TrustedEffectCommitter` boundary
that executes or directly verifies the defined effect and owns no general UI
authority. Untrusted application code cannot supply a success bit or effect
digest to obtain a receipt.
The cryptographic provider does not depend on application UI or transport
implementations.

The logical trusted computing boundary may be split across isolated processes,
but every crossing then uses authenticated IPC and server-side capabilities:

| Boundary member | Narrow authority | Consequence of compromise |
|---|---|---|
| Policy/session service | Decisions, owner registry, handshake state, local grant state, readiness transitions | All BoundSession authorization claims fail |
| Policy verifier and monotonic/transactional store | Policy origin, freshness, CAS, replay tombstones, authorization and effect journals | Policy, recovery, or ordering claims fail |
| Crypto provider and identity signer | KEM/key schedule, session MACs, identity signatures | Authentication or secrecy claims fail |
| Receipt-key service | Receipt-key handles and MAC issuance only after an authenticated committer outcome | Receipt authenticity fails |
| Purpose-specific `TrustedEffectCommitter` | One named renderer, input, or durable-file completion contract | Effect correspondence for that purpose fails |
| OS/kernel primitives | IPC credentials, process isolation, renderer/input completion, filesystem durability | The dependent local claims fail |

Application modules, general adapters, discovery, and transport are untrusted.
Colocating a boundary member with untrusted application code yields only the
honest-host profile for the affected claim.

BoundSessionV1 has no suite negotiation. A policy snapshot names exactly one
wire cryptographic profile and one protocol version. If a peer does not support
that profile or does not present the expected policy identity, the attempt fails.
A classic-capable compatibility path is a different protocol identity. No UI
preference, environment variable, fallback helper, or platform factory may
re-select a suite or provider after `LocalAuthenticatedDecision` is created.

Version 1 is scoped to a managed pairing domain in which both peers possess the
same signed policy root, version, and digest before the handshake. Supporting
different but compatible local policies would require a separately specified
policy-compatibility relation and is not inferred by this design.

## 2. Core types

### 2.1 AuthenticatedPolicySnapshot

An immutable policy snapshot is created only after:

- exact signed-policy bytes verify under a code-pinned root;
- the root namespace and first-enrollment authority are authorized;
- `(policyVersion, policyDigest)` advances through monotonic compare-and-swap;
- the policy names one protocol version, wire profile, suite, hybrid profile,
  key format, and purpose-authorization rule set; and
- the snapshot has not expired or been revoked according to the policy service's
  explicit freshness contract.

The snapshot is local. It does not assert that a remote peer actually executed a
provider or policy merely because the peer signed the same wire policy identity.

### 2.2 LocalAuthenticatedDecision

The trusted policy service consumes a snapshot and an exact session request. It
authenticates the local IPC caller, verifies that the snapshot authorizes the
expected peer and the exact canonical `PurposeV1`, validates the current local
owner, and checks runtime capabilities. It then creates a server-side decision
entry binding:

```text
callerPrincipal
localIdentity and localRole
expectedPeerIdentity
purposeDigest
localOwnerBinding
localEffectScopeSet
protocolVersion
wireCryptoProfileId
suiteId
hybridProfileId
keyFormatId
localPolicyRootRecordId
policyRootKeyFingerprint
policyVersion
policyDigest
decisionEpoch
localProviderIdentity
expiresAt
```

`wireDecisionDigest` is a domain-separated hash of the peer-visible projection:

```text
protocolVersion
wireCryptoProfileId
suiteId
hybridProfileId
keyFormatId
policyRootKeyFingerprint
policyVersion
policyDigest
purposeDigest
ordered initiator and responder identities and roles
```

The local provider identity, owner, effect scopes, and policy-store record ID are
deliberately excluded from the wire projection. The wire uses only the trust
root's public-key fingerprint. The protocol can establish agreement on
cryptographic wire semantics, not that heterogeneous endpoints execute
byte-identical providers.
Each endpoint must separately prove that its local decision refined to its local
provider.

The decision handle is an authenticated IPC reference to a server-side table
entry, not a caller-supplied byte descriptor. The service binds the reference to
the OS-authenticated caller principal, IPC channel, peer, purpose, owner, epoch,
expiry, and one-time operation sequence. It rejects transfer across principals,
expired or revoked handles, replayed sequences, and owner replacement. A random
identifier without authenticated IPC and a server-side entry is insufficient.

An implementation without a separate process or equivalent isolation may claim
only an honest-host API-discipline profile. It cannot claim resistance to hostile
code in the same address space.

### 2.3 PurposeV1

`PurposeV1` is a closed tagged union, never a string-keyed metadata map:

```text
remoteDesktop {
  mode: viewOnly | interactive
  capabilityBitmap: UInt64
}

fileTransfer {
  direction: initiatorToResponder | responderToInitiator
  transferId: Nonce32
  declaredBytes: UInt64
  contentSha256: Hash32
}
```

The remote-desktop capability commitment is:

```text
H("bound-session/capabilities/v1" || Encode(mode, capabilityBitmap))
```

The purpose digest is:

```text
H("bound-session/purpose/v1" || Encode(PurposeV1))
```

`direction` is always relative to the authenticated protocol roles. Policy fixes
the allowed capability bits, maximum declared file length, direction, and peer
authorization. Each variant has independent validation and receipt semantics. A
grant for one variant cannot be reinterpreted as the other.

### 2.4 LocalEffectScopeSet

The policy/session service constructs an endpoint-private, closed set of typed
effect capabilities while creating the local decision. It never accepts a
generic `execute(effect)` target:

```text
presentationScope {
  surfaceCapability
  rendererCodeIdentity
  allowedFrameFormatAndBounds
}

inputScope {
  desktopOrSessionCapability
  allowedActionClassBitmap
}

fileReceiveScope {
  preopenedDirectoryCapability
  canonicalLeafName
  replacePolicy: createOnly | replaceExact
}
```

The capabilities are server-side, caller- and owner-bound, non-serializable, and
excluded from the wire projection. The decision and grant records bind their
domain-separated digest. A purpose authorizes only the scope variants needed by
the endpoint's protocol role; ordinary application code cannot substitute a
surface, input target, directory, leaf name, or replace policy after the
decision.

### 2.5 PeerSessionId and LocalOwnerBinding

`peerSessionId` is a fresh 32-byte initiator value from the approved CSPRNG and is
authenticated by both peers. The initiator rejects reuse against its bounded
pending/recent-attempt store; the responder persists an accepted-session
tombstone for the policy-defined TTL. It identifies the protocol attempt and is
safe to place on the wire.

`LocalOwnerBinding` never appears on the wire. It contains the local caller
principal, connection generation, operation token, driver identity, and arbiter
lease. Both endpoints have independent owner bindings; equality is neither
expected nor claimed.

Simultaneous open is not handled inside BoundSessionV1. A trusted local
pairing-layer arbiter atomically issues one unique transport-owner lease and
selects one initiator before either endpoint requests a decision. A superseded
transport invalidates its local owner binding and cannot publish a grant. The
formal state model treats lease uniqueness and invalidation as explicit
assumptions rather than silently merging concurrent attempts.

### 2.6 BoundSessionContextV1

The pre-KEM context uses a canonical, prefix-free, closed encoding. It includes:

```text
domainSeparator = "bound-session/context/v1"
protocolVersion
initiator and responder roles
initiatorIdentityFingerprint
expectedResponderIdentityFingerprint
recipientKemPublicKeyDigest
wireDecisionDigest and its complete peer-visible fields
PurposeV1 and purposeDigest
clientNonce
peerSessionId
```

Message A carries the complete canonical `PurposeV1`; there is no unopened
purpose commitment. The responder re-encodes the value and verifies
`purposeDigest` and `wireDecisionDigest` before decapsulation. Unknown critical
fields, duplicate fields, non-canonical ordering, length overflow, trailing
bytes, and invalid enum values fail before KEM execution.

The pre-KEM context cannot contain a responder nonce or a ciphertext that does
not yet exist. Later signatures, the complete transcript digest, and the key
schedule bind those values. The model and paper must keep pre-KEM context
agreement and final transcript agreement as separate properties.

### 2.7 BoundSessionGrant

The service-side immutable `BoundSessionGrantRecord` is published only after the
local authorization and bilateral-ready transitions in Section 4. It binds:

```text
local caller principal and LocalOwnerBinding
LocalEffectScopeSet digest and server-side capability references
peer identities and roles
peerSessionId
decisionEpoch and policy identity
wire crypto profile and suite
localProviderIdentity
contextDigest and transcriptDigest
PurposeV1 and purposeDigest
allowed logical channels
direction-separated key handles
authorizationCommitId
localGrantId, expiry, and next operation sequence
sharedGrantId, bilateralReadyDigest, and peer authorization commitment
```

Application code receives only a caller-bound, non-serializable
`BoundSessionGrantHandle` and purpose-specific typed channel API. Reflection or
encoding of the handle cannot reveal or reconstruct the service-side record. The
application does not receive raw root keys, KEM shared secrets, owner tokens,
decision epochs, local provider identity, local grant/commit identifiers, or a
generic channel that can silently change purpose.

### 2.8 Shared grant readiness

Each endpoint persists a monotonic local product state:

```text
Handshaking -> AuthorizationCommitted
AuthorizationCommitted -> LocalReadyPrepared
AuthorizationCommitted -> PeerReadyValidated
LocalReadyPrepared + PeerReadyValidated + FinalOwnerCAS -> Enabled
any nonterminal state -> Revoked | Expired
```

`LocalReadyPrepared` and `PeerReadyValidated` may occur in either order after
Finished, but `Enabled` requires both plus the final owner CAS. An early peer
ready is stored as at most one bounded candidate for its `peerSessionId` and
role; conflicting or additional candidates are rejected rather than queued.
`Revoked` and `Expired` are terminal for that local grant.

`localGrantId`, `decisionEpoch`, `authorizationCommitId`, and
`LocalOwnerBinding` remain endpoint-private. They never serve as if both peers
shared one local grant. Instead, each endpoint derives the same public session
authorization name:

```text
sharedGrantId = H(
  "bound-session/shared-grant/v1" ||
  Encode(protocolVersion,
         ordered peer identities and roles,
         policy identity and wire crypto profile,
         peerSessionId,
         purposeDigest,
         contextDigest,
         transcriptDigest))
```

After its local authorization transaction, an endpoint derives an opaque
`issuerAuthorizationCommitment` over its issuer role, `sharedGrantId`, local
grant identifier, decision epoch, authorization transaction identifier, and
authorization-record digest. `localGrantId`, `authorizationCommitId`, and a
separate `authorizationCommitNonce` are CSPRNG-derived 256-bit values stored in
the local transaction; the nonce is never sent:

```text
issuerAuthorizationCommitment = H(
  "bound-session/authorization-commit/v1" ||
  Encode(issuerRole,
         sharedGrantId,
         localGrantId,
         decisionEpoch,
         authorizationCommitId,
         authorizationRecordDigest,
         authorizationCommitNonce))
```

A peer cannot open this commitment. A valid
`GrantReadyV1` only authenticates that the peer's trusted service asserted a
matching local commit under the protocol threat model; it is not remote
attestation of the peer's provider, storage, or application effect.

`GrantReadyV1` is authenticated with the direction-specific session-control key
and canonically encodes the protocol version, `peerSessionId`, issuer role,
`sharedGrantId`, `issuerAuthorizationCommitment`, and a ready-sequence value.
Once an endpoint
has its own canonical ready message and the peer's valid message, it computes:

```text
bilateralReadyDigest = H(
  "bound-session/ready-set/v1" ||
  Encode(initiatorGrantReadyV1, responderGrantReadyV1))
```

The role-ordered encoding covers both exact authenticated message bodies and
their tags.

Before the first network send, the service atomically stores the exact canonical
`GrantReadyV1` body, authentication tag, and outbound sequence in the pending
grant outbox. Recovery retransmits those stored bytes; it neither samples a new
commitment nonce nor generates a different valid ready value for the same role
and `sharedGrantId`.

Readiness is not a distributed atomic commit and does not use a global clock.
For each endpoint $E$ with peer $P$, the required local event order is:

```text
Authz_E -> SendReady_E
RecvReady_E(P) -> FinalOwnerCAS_E -> Enable_E
Enable_E -> TrustedEffectCommit_E -> ReceiptIssued_E
```

Message loss, timeout, or later remote revocation can leave only one endpoint
temporarily enabled. This does not authorize an effect at the other endpoint:
every effect path checks its own local `Enable` state and current grant before
executing. Termination and prompt distributed revocation are separate liveness
properties, not consequences of the ready exchange.

Before local enablement, an endpoint may send an authenticated `GrantAbortV1`;
after enablement it may send `GrantRevokeV1`. Each message binds protocol
version, role, `peerSessionId`, `sharedGrantId`, control sequence, and a closed
reason code under the direction-specific control key. A valid peer abort/revoke
moves the receiving local grant to `Revoked` and blocks new effects after a local
state transaction. It cannot erase an already committed effect or receipt.
Expiry is enforced locally even if a termination message is lost; prompt remote
revocation remains a liveness property.

Identical ready retransmissions are idempotent. A changed message for the same
role and `sharedGrantId`, an old session, a sequence replay, a timeout, or a
revoked local commit fails explicitly. Before changing a grant to `enabled`, the
trusted service again compare-and-swaps the exact local owner, decision epoch,
and authorization transaction, then stores the peer ready message and
`bilateralReadyDigest`. Application traffic received before local enablement
cannot cause an effect. Crash recovery may retransmit the identical local ready
message only after revalidating the same owner and commit; otherwise it revokes
the pending grant.

## 3. Protocol flow

1. The initiator's trusted service creates a local decision for one peer,
   purpose, owner, and policy-selected wire profile.
2. The initiator creates canonical `BoundSessionContextV1` and runs the
   ContextBound PQ/T KEM under that context.
3. Message A carries the KEM material, full purpose, wire decision projection,
   `peerSessionId`, and critical extensions. Its signature covers the exact
   encoded bytes.
4. The responder verifies that the policy identity equals its managed-domain
   snapshot, requests its own local decision for the same wire projection and
   purpose, and rejects any mismatch before releasing business-capable key
   material. It decapsulates using the same canonical pre-KEM context.
5. Message B confirms rather than re-selects the fixed wire profile. It
   authenticates both identities, both nonces, Message A, responder material,
   policy identity, purpose, and `peerSessionId`.
6. The root key schedule absorbs the complete Message A/Message B transcript and
   the context digest. A second schedule separates keys by purpose, logical
   channel, and direction.
7. Both peers exchange direction-specific Finished messages over the complete
   transcript.
8. Each trusted service independently commits a local authorization record and
   exact-owner pending grant through the transaction in Section 4.
9. The services exchange authenticated `GrantReadyV1` values, derive the same
   `sharedGrantId` and role-ordered `bilateralReadyDigest`, and reject any
   mismatch or replay.
10. Each service revalidates its private owner and local commit while atomically
    marking the grant enabled. Only then is `BoundSessionGrant` published to its
    authenticated caller and may business traffic reach a trusted effect path.
11. Business success requires a verified purpose-specific effect receipt; the
    authorization audit record is not itself a success receipt.

## 4. Authorization, readiness, and diagnostic audit

The trusted service owns the local owner registry, pending-grant store, and audit
transaction boundary. After the final network await, it performs one local
transaction with no external await:

```text
CommitAuthorization(expectedOwner, pendingGrant, auditRecord):
  compare-and-swap exact LocalOwnerBinding and decision epoch
  atomically store authorized grant state and matching audit authorization record
  return authorizationCommitId
```

The audit record covers the complete local security tuple: caller, peer,
`peerSessionId`, policy identity, decision epoch, wire profile, local provider,
purpose, context digest, transcript digest, owner, grant identifier, and commit
result. External/exported identifiers may be redacted, but internal routing uses
an exact, distinct identifier.

The record means “this local service authorized this grant,” not “the peer
observed an application effect.” If the process crashes after authorization but
before publication, recovery uses the transaction identifier to either revalidate
the exact owner and reissue the same grant or revoke it and append an abort/revoke
record. It never invents an application success. A persistent implementation
requires a write-ahead or transactional store and a state-model proof; an
in-memory implementation may claim only same-process consistency and loses both
grant and diagnostic audit state on crash.

Every asynchronous boundary before the transaction revalidates the expected
local owner. The transaction performs the final compare-and-swap, closing the
race between the last check and authorization. Grant publication rejects any
owner, epoch, expiry, or operation-sequence change after the commit.

The initial transaction creates a pending grant, not a business-capable grant.
Publication additionally requires the bilateral-ready transition from
Section 2.7. Every purpose operation rechecks that the local grant remains
enabled and unrevoked. A ready assertion from the peer does not authorize a
different local owner or survive local revocation.

## 5. Effect receipts

All effect receipts use a purpose-separated receipt key and a canonical common
header:

```text
domainSeparator = "bound-session/receipt/v1"
protocolVersion
peerSessionId
sharedGrantId
bilateralReadyDigest
issuerRole and issuerAuthorizationCommitment
policyDigest and wire profile
purposeDigest
contextDigest and transcriptDigest
effectType
operationId
monotonicSequence
resultCode
effectDigest
```

The receipt is authenticated with a direction-specific MAC derived from the
session root and purpose. The verifier checks `sharedGrantId`, the complete
bilateral ready set, the receipt issuer's previously authenticated authorization
commitment, role, direction, sequence, operation identifier, and effect digest.
Endpoint-private grant identifiers and decision epochs are not cross-endpoint
receipt fields. Operation identifiers are idempotency keys: a duplicate may
return the identical stored result, while a different request under a used
identifier is rejected. Receipts from another session authorization, ready set,
purpose, direction, or sequence are replay failures.

Only one of three sealed ports---`PresentationCommitter`, `InputCommitter`, or
`DurableFileCommitter`---can authorize its corresponding success receipt. There
is no generic `execute(effect)` port. Each committer receives a one-use,
service-created typed operation capability bound to the enabled local grant,
authenticated caller, owner generation, `LocalEffectScopeSet` target, exact
canonical request digest, operation identifier, sequence, and expiry. It either
performs the effect itself or obtains the named trusted platform completion
event. The receipt service accepts the outcome
only over an authenticated channel from that committer and derives the effect
digest from the canonical request plus trusted outcome. It never MACs a
caller-supplied success flag, result code, or effect digest, and the receipt key
is unavailable to ordinary application modules.

Each purpose uses a server-side target capability that an ordinary application
cannot replace. The renderer capability binds the intended surface, decoded
buffer digest, frame identifier, and presentation fence. The input capability
binds the target session/window, canonical action, and OS acceptance result. The
file capability binds a service-owned destination root, transfer identifier,
temporary object, final relative name, and required synchronization operations;
path resolution rejects absolute paths, traversal, and symlink substitution.
Where an OS permission such as input injection has a wider blast radius than the
typed port, the committer runs in a separately authenticated process with the
minimum available entitlement and repeats the target/action checks internally.
The paper reports any irreducible platform permission excess.

Remote-desktop receipts additionally bind the capability bitmap. A first-frame
success means that the trusted renderer verified the frame, submitted it to the
intended surface, and observed the platform presentation completion or fence; it
does not prove that a human saw the pixels. Interactive-control success means
that the trusted input committer submitted the exact canonical action and the OS
input API returned its defined acceptance result; it does not prove a later
physical consequence. File success requires the trusted receiver to verify the
declared length and digest, write and synchronize the content, atomically install
it, synchronize the containing directory or platform equivalent, and then
record the durable-store commit identifier. A platform without the required
durability primitive cannot issue the durable-success code.

The core journal and independent committer journal use the same operation ID and
request digest with these monotonic states:

```text
Reserved(requestDigest)
  -> MayHaveStarted
  -> Committed(outcome, exactReceiptBytes) | Rejected | Ambiguous
```

The committer journal must be queryable during recovery. An exact duplicate in
`Committed` returns the stored receipt bytes; a conflicting request is rejected.
`MayHaveStarted` is reconciled only when the platform exposes a trustworthy
query or transactional effect. Otherwise it becomes `Ambiguous` and cannot be
blindly replayed or converted to success. File commit may be reconcilable;
input injection usually is not. The state model covers crashes before effect,
between effect and journal commit, and between journal commit and receipt
transmission.

A missing receipt after a potentially applied operation is an explicit ambiguous
outcome. It is neither success nor permission for a blind non-idempotent retry.

## 6. Downgrade rules

- A policy-bound PQ/T attempt never produces a business-capable classic session.
- Network errors, timeouts, malformed input, signature failure, identity failure,
  queue overflow, cancellation, ABI failure, provider failure after send, and
  resource exhaustion are terminal for that attempt.
- If a separate compatibility mode permits classic operation, it uses a distinct
  protocol identity and a peer-authenticated `AttemptEvidenceV1` declaration.
- Such a declaration proves only what the endpoint asserted and signed. It does
  not prove that a local hardware or provider failure actually occurred.
- A control-only bootstrap channel is a separate purpose and cannot carry or
  derive business-channel keys before a required PQ/T rekey.
- Unknown peers and old protocol versions never trigger an automatic semantic
  downgrade from BoundSessionV1.

## 7. Error and resource semantics

All public results distinguish at least:

- invalid, expired, revoked, or unauthorized policy;
- rollback or equal-version equivocation;
- caller, peer, purpose, owner, or decision authorization failure;
- unsupported wire profile or local provider;
- malformed/non-canonical wire input;
- peer identity or transcript authentication failure;
- KEM/combiner failure;
- timeout, cancellation, overload, and resource rejection;
- stale owner, decision epoch, handle, or operation sequence;
- authorization-transaction failure;
- grant-ready mismatch, replay, timeout, or bilateral-enable failure;
- untrusted or unavailable effect committer;
- application rejection;
- ambiguous application outcome.

Policy defines maximum message length, declared file length, concurrent pre-auth
attempts per principal and source, outstanding handles per caller, operations per
grant, queue depth, audit retention, handle TTL, and retry budget. Admission is
checked before expensive signature or KEM work whenever a trustworthy cheap
identity key is available. All capacity rejection is explicit and never changes
the cryptographic profile.

No error is converted to an empty value, default suite, success state, or
unrecorded fallback. Resources, handles, queued operations, and key material have
defined release behavior on every terminal result.

## 8. Security invariants

The integrated formal work must state and test at least:

- `PolicySnapshotOrigin`
- `PolicyMonotonicity`
- `PurposeAuthorizedByLocalDecision`
- `LocalDecisionWireProjection`
- `LocalProviderRefinement`
- `NoPolicyBoundBusinessFallback`
- `CanonicalPreKemContextAgreement`
- `FinishedInjectiveAgreement`
- `HybridSecrecyIfEitherComponentHolds`
- `NoForwardSecrecyForStaticQSuite` as a witness unless an additional ephemeral
  contribution is specified and proved
- `NoCrossPurposeKeyReuse`
- `ExactLocalOwnerTransaction`
- `BilateralGrantReadiness`
- `PolicyUpdateSessionSemantics`
- `AuthorizationAuditBeforeGrantPublication`
- `TrustedEffectCommitterAuthority`
- `ReceiptEffectCorrespondence`
- `ArtifactBinding`

Every universal security lemma requires an executability lemma and a negative
control or attack witness that would fail if the relevant mechanism were removed.

## 9. Explicit non-goals for version 1

Unless separately implemented and evidenced, the protocol does not claim:

- security after endpoint, OS, root, or any trusted boundary member in Section 1
  is compromised;
- hostile same-process caller resistance in an honest-host implementation mode;
- remote attestation that a peer executed the provider or policy it advertised;
- malicious compiler resistance or formal specification-to-binary refinement;
- universal denial-of-service resistance or native-operation cancellation;
- durable, non-repudiable, or root-resistant audit;
- metadata unlinkability;
- post-compromise or forward secrecy for a static-only KEM suite;
- production deployment, release publication, or cross-platform parity.
