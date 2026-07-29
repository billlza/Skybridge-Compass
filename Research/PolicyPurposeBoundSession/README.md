# Policy-to-Purpose-to-Byte TIFS Research Line

This directory is an independent research line for a new IEEE TIFS manuscript.
It does not revise either of the earlier manuscripts:

- `Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex`
- `/Users/bill/Desktop/pqt_hybrid_suite/paper/q-periapt.tex`

Those manuscripts and their artifacts are read-only upstream inputs. Results,
proof counts, and platform claims from them are not automatically evidence for
this work.

## Research question

Can a heterogeneous peer-to-peer system ensure that an application receives a
session capability bound to one authenticated migration policy, one application
purpose, one PQ/T hybrid realization, one transcript, and one exact session
identifier plus its separately authorized local owner, despite an active network
attacker and implementation diversity?

The proposed object is `BoundSessionV1`. Its central invariant is
**policy-to-purpose-to-byte continuity**: each endpoint's local authenticated
decision must authorize the same peer-visible policy, purpose, and wire profile;
the purpose is bound into the key-establishment context and transcript; both
peers confirm the resulting keys; and the accepting endpoint's exact-owner
transaction commits the pending grant plus its authorization record. Both
authenticated readiness values and a final owner check precede publication.
Durability is claimed only by the persistent profile; application success remains
a separate receipt from a trusted, purpose-specific effect committer.

## Status

This is a design-stage manuscript scaffold, not a submission candidate. The
24-claim ledger intentionally starts with only `design_only`, `pending`, and
`not_started` states, and its validator rejects every attempted `passed` state
until a separate manifest-aware evidence verifier exists. In particular, the directory currently contains no new
integrated protocol proof, final-source implementation evidence, physical-device
result, or publication evidence.

Before submission, the Q-Periapt manuscript's external review status must be
resolved. IEEE policy does not permit substantially overlapping manuscripts to
be under active consideration concurrently. A TIFS submission must also disclose
the prior TDSC rejection and include the required review-response document.

## Directory layout

```text
paper/       Independent main manuscript, supplement, and bibliography
protocol/    Normative design contract for BoundSessionV1
formal/      Proof responsibilities and composition boundary
artifact/    Machine-readable claim ledger and its validator
submission/  Prior-review mapping and submission-only checks
```

Future implementation work should add a single protocol core, an isolated local
policy/session service with authenticated IPC, narrow trusted effect committers,
and thin untrusted platform adapters. It must not create independent Swift and
Rust authorities for suite, policy, fallback, purpose authorization, session
ownership, or effect-receipt success.

Before implementation begins, freeze the field IDs and bounds, canonical codec,
hash/MAC/KDF algorithms, readiness/effect persistence model, typed local effect
scopes, and crash semantics in one explicit state-model tool. The current prose
is not an implementation-ready wire specification.

## Build and checks

```sh
cd Research/PolicyPurposeBoundSession
make check
```

`make check` validates the claim ledger, runs its unit tests, builds both PDFs,
and fails on LaTeX warnings or bad boxes.

## TIFS length budget

The initial manuscript target is at most 13 double-column pages, including
references. The working budget is:

| Part | Pages |
|---|---:|
| Introduction | 1.00 |
| Background and related work | 1.00 |
| System and threat model | 1.00 |
| Contract and protocol | 1.50 |
| Security analysis | 2.50 |
| Implementation and evidence chain | 0.75 |
| Evaluation | 2.50 |
| Discussion, limitations, conclusion | 0.75 |
| References | 2.00 |

The supplement target is at most six pages. It may contain detailed encodings,
proof derivations, extended evidence tables, and reproduction instructions, but
not an unreferenced theorem or a second contribution track.

## Evidence discipline

- A component theorem is upstream evidence, not a proof of the composed system.
- Source presence is not execution evidence.
- Unit and conformance tests are not physical-device or network evidence.
- A package hash is not runtime or source-to-binary refinement evidence.
- A successful handshake is not application success without an owner-bound
  remote-control receipt or a durable file-transfer receipt.
- Every submitted table and figure must rebuild from raw data bound to the final
  source, model, toolchain, and binary identities.
