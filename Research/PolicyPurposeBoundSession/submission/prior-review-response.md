# Prior Review and Resubmission Mapping

Status: working submission note. This is not yet the supporting document required
by IEEE Signal Processing Society. Before submission it must include verbatim
quotations of all relevant prior reviews and the final manuscript line mapping.

## Prior manuscript

- Manuscript: `TDSC-2026-01-0318`
- Decision: reject
- Decision date shown in the supplied letter: 2026-06-02
- Source decision: `/Users/bill/Downloads/TDSC-2026-01-0318 - Decision.pdf`

The new manuscript is maintained independently. It is not presented as an
unmodified resubmission, but it is derived from related prior work and therefore
must disclose the rejection and explain the technical delta.

## Review-driven requirements

| Prior concern | Root cause | Required response in the new manuscript | Evidence gate |
|---|---|---|---|
| Original contribution was unclear | The old manuscript mixed migration policy, state-machine engineering, application motivation, and artifact process without one theorem-sized object | Define policy-to-purpose-to-byte continuity as one acceptance invariant spanning local authorization, bilateral readiness, and trusted effect correspondence; limit the paper to three contributions | Normative protocol, integrated theorem statement, ablation showing each link is load-bearing |
| A proof sketch was insufficient | The old symbolic claim was not a composed proof of the actual Q-backed path, and the cited frozen artifact did not match the later active-attacker model | Build one new integrated network model plus a separate state/commit model; bind both to the final evidence root | Clean proof reports, anti-vacuity lemmas, negative controls, traceability matrix |
| The paper was difficult to read and resembled a list of lists | The main and supplement accumulated large matrices, implementation inventories, and repeated taxonomies | Organize around four research questions and one causal chain; keep only result-bearing tables in the main text | 13-page limit, six-page supplement target, independent readability review |
| Generic handshake versus remote desktop/file transfer was unclear | Applications were mainly motivation; their authorization and success semantics were not bound to the handshake | Bind a closed `PurposeV1` into the KEM context, transcript, keys, grant, and application receipts | Real first-frame/control-apply and durable file-receipt experiments |
| Apple ecosystem dependence | Portable architecture statements and static checks were used where real non-Apple execution was needed | Run one final protocol core on real Apple and non-Apple endpoints | Physical/runtime matrix with authenticated handshake and bidirectional application receipts |
| Supplementary layout was defective | Tables were too dense and, in the submitted version, overlapped | Rebuild the supplement from a short template and make warning/bad-box checks fatal | Render every final page and inspect at readable scale |
| Abstract and conclusion lacked focus | They enumerated mechanisms and claims rather than answering one question | Report the contract, exact assumptions, primary security result, and primary measured cost only | Final abstract review against the claim ledger |

## New technical delta required before submission

1. A new protocol identity and wire contract; no silent reinterpretation of the
   old suite identifier.
2. One isolated local decision authority per endpoint, binding caller, peer,
   purpose, owner, policy, wire profile, local provider, and epoch; peers agree
   on the wire projection rather than private provider identity.
3. A closed application-purpose schema and purpose-separated key schedule.
4. An exact-owner transaction that stores a pending grant and diagnostic
   authorization record, followed by authenticated bilateral readiness and a
   second owner check before publication.
5. A new integrated formal model rather than a concatenation of previous models.
6. Final-source Q-to-session implementation on Apple and non-Apple endpoints.
7. Trusted-effect remote-control and file-transfer receipts that ordinary
   application code cannot mint, plus matched baselines, attacks, ablations, and
   source-bound raw evidence.

## Submission blockers

- Confirm that no substantially overlapping Q-Periapt manuscript remains under
  active review, or obtain explicit editorial authorization before submission.
- Replace this summary with the SPS-required verbatim review excerpts and exact
  response locations.
- Confirm the final main PDF does not exceed 13 double-column pages.
- Confirm the supplement does not introduce an unreferenced theorem or a second
  contribution.
- Provide a history-free review artifact whose contents rebuild every submitted
  figure and table from the final evidence root.
