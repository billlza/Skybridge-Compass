# SkyBridge Compass Formal Model (v2)

This directory contains the reviewer-facing Tamarin artifact for the
SkyBridge handshake. The model is a **Dolev-Yao symbolic model with an
active network attacker**: every protocol message is sent with `Out()`
and received with `In()`, so Tamarin's built-in adversary fully mediates
the channel (drop / inject / reorder / replay / synthesise). All security
lemmas are proved against that active attacker.

> The earlier `skybridge_v2.spthy` proved 14 lemmas against an *empty*
> adversary (no `In()/Out()`, no key compromise, `VerifiedSigB` was an
> unconditional action label), so every lemma was a tautology. That file
> is preserved as `skybridge_v2_empty_adversary.spthy.bak` for history.
> The current `skybridge_v2.spthy` replaces it with a real model.

## Files

- `skybridge_v2.spthy`: main theory used by the paper (active adversary).
- `skybridge_v2_empty_adversary.spthy.bak`: the superseded empty-adversary
  artifact (kept only to make the change explicit; do not cite it).
- `skybridge_minimal.spthy`: earlier reduced sketch (reference only).
- `run_tamarin.sh`: helper script (`./run_tamarin.sh [theory]`).

## How to run

```bash
cd formal
bash run_tamarin.sh                 # proves skybridge_v2.spthy
# or directly:
tamarin-prover --prove --derivcheck-timeout=0 skybridge_v2.spthy
```

`--derivcheck-timeout=0` disables only the preprocessing derivation-check
*timeout heuristic* (the one item that ever tripped the wellformedness
banner on this DH+KEM theory). It does not affect proof soundness; it lets
the source/derivation analysis run to completion so the report carries no
"results might be wrong" warning. With it, the full run completes in ~50s
and reports **0 wellformedness warnings**.

### Toolchain note (macOS)

Tamarin's rewriting backend `maude` (installed from `tamarin-prover/tap`)
needs `libtecla` and `libsigsegv` at runtime. If `tamarin-prover` reports
"`maude` executable not found / does not work" with a `dyld: Library not
loaded` error, run `brew install libtecla libsigsegv`.

## Adversary capabilities modelled

- **Active Dolev-Yao network**: all of MessageA, MessageB, and the two
  Finished frames go through `Out()/In()`.
- **Long-term keys + pairing pins**: `Register_Identity` creates
  `!Ltk($A,~sk)`/`!Pk($A,pk(~sk))`; `Register_KEMKey` creates the static
  KEM key `!KemLtk`/`!KemPk`. `Pair_OOB` pins a peer id to *both* keys over
  an authentic out-of-band channel (`!Pin`). Identity/KEM registration and
  pairing are once-per-agent (restrictions), matching one device = one
  canonical, pinned identity.
- **Key compromise**: `Reveal_Ltk` (`LtkReveal($A)`), `Reveal_KEM`
  (`KemReveal($A)`), and `Reveal_Eph` (`EphReveal(x)`), so secrecy/FS are
  conditioned on which secret leaked and *when*.
- **Symbolic KEM**: `kemenc/kemdec` equational theory
  (`kemdec(kemenc(ss, kempk(sk)), sk) = ss`), so session-key secrecy is
  conditioned on holding the responder's static KEM secret (the v1 trust
  root). The v2 FS suite (0x0102) additionally absorbs a fresh ephemeral
  DH secret `g^(xa*xb)` contributed by *both* sides.
- **Transcript-authenticated acceptance**: `sigA` and `sigB` are real
  `sign/verify` over the actual preimages from the Rust/Swift sources
  (`sigB` binds `transcriptHashA || selectedSuite || responderShare ||
  serverNonce || ...`). Responders verify `sigA`; initiators verify `sigB`.
  Acceptance is *not* an unconditional label.

## Lemma inventory (exact names in `skybridge_v2.spthy`)

### Existence / sanity (anti-vacuity)

- `Exists_PQCv1_Session`            — a full v1 session is reachable.
- `Exists_PQCv2_Session`            — a full v2 (FS) session is reachable.
- `Exists_Default_Classic_Downgrade`— default-policy classic downgrade is reachable.
- `V1_LacksForwardSecrecy_Witness`  — exists-trace proof that v1 is NOT
  forward-secret (root recovered after a *later* KEM-key reveal); witnesses
  that the v1/v2 separation is real, not an artifact.

### Security lemmas

- `NegotiationIntegrity_AcceptedWasOffered` — the suite an initiator
  accepts was offered in that session (negotiation integrity).
- `SigB_Authentic_or_Compromised`           — a verified MessageB exists
  only if the pinned responder issued it, or its key was revealed.
- `Injective_Agreement_I_with_R`            — Lowe injective agreement:
  initiator commit ⇒ matching unique responder run, unless the responder
  key was revealed.
- `Secrecy_SessionKey_HonestCase`           — with no compromise, the root
  is unknown to the active attacker.
- `WeakFS_v1`                               — v1 root secret iff the static
  KEM key stays honest (weak FS).
- `ForwardSecrecy_v2`                       — v2 root stays secret even if
  ALL long-term keys (signing + static KEM) leak *after* the session, as
  long as the ephemerals are not revealed (perfect forward secrecy).
- `NoClassicUnderStrictPQC`                 — a strictPQC initiator never
  accepts classic (downgrade resistance under strict policy).
- `NoSilentClassicFallback_Default`         — under default policy, a classic
  acceptance is always preceded by the explicit local fallback gate; the
  attacker cannot manufacture it over the network (no timeout-forced
  downgrade).
- `ClassicRequiresDowngradeOrClassicPolicy` — any classic acceptance carries
  recorded downgrade evidence or is an explicit classic-only session.

## Last verified status

All 13 lemmas **verified** (Tamarin 1.10.0, Maude 2.7.1), 0 wellformedness
warnings, ~50s. See `tamarin-report/skybridge_v2_summary.txt` and the dated
artifacts under `../Artifacts/`.

## Modeling notes / scope

- Negotiation integrity and downgrade-resistance lemmas are anchored on the
  *initiator's* sigB-verified commit, because policy is the initiator's
  property and the Rust initiator is where `offered_suites.contains(selected)`
  is enforced. The responder's view over an attacker-forged MessageA `sid`
  (only possible after an initiator-key reveal) is intentionally out of scope.
- Forward secrecy uses the standard PFS scoping: long-term keys may leak
  *after* the session (that is the guarantee); a pre-session key reveal makes
  the attacker a live MITM, which no scheme can defend and which is excluded.
- Pairing storage and platform-API details are abstracted; the KEM and the
  ephemeral DH are the standard symbolic abstractions.
