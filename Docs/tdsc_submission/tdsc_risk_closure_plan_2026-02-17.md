# TDSC Risk-Closure Plan (A-F)  
Date: 2026-02-17

## Scope and target
This plan is to close the reviewer risks A-F from "high revision/desk-reject trigger" to "claim-evidence aligned and auditable".  
Primary manuscript: `Docs/tdsc_submission/paper.tex`  
Supplementary: `Docs/TDSC-2026-01-0318_supplementary.tex`

## Current status summary
- Main paper already separates mechanism-level vs deployment-level claims and has explicit limitations (`paper.tex` section `Limitations and Future Work`).
- Formal artifact exists and verifies 9 lemmas (`formal/tamarin-report/skybridge_v2_summary.txt`).
- Real-network micro-study currently exposes 3 labels (1 direct + 2 overlay) (`Docs/supp_tables/s9_realnet_microstudy.tex`).
- Cross-platform consistency report now passes with no blocker-level or warning-level gaps (`Artifacts/interop_consistency_2026-01-23.md`).
- Runtime suite policy is now explicit and version-tiered:
  - Android 17+: `X-Wing -> PQC(liboqs) -> classic` (when support is available)
  - Android 14-16: `PQC(liboqs) -> classic`
  - Android 13 and below: `classic`
  - Ubuntu 24-25+: `X-Wing -> PQC(liboqs) -> classic`
  - Ubuntu 22-23: `PQC(liboqs) -> classic`
  - Ubuntu 20-21: `classic`
- Step-2 execution against EC2 Linux completed on 2026-02-17: direct-path evidence was initially blocked by path policy/misconfigured ingress, then closed after SG correction on production EC2 (`54.92.79.99`) with reproducible direct success (100/100).

## Cross-platform code-audit snapshot (2026-02-17)
This snapshot is the current "as-implemented" baseline and is treated as the source-of-truth before adding paper claims.

| Platform | Protocol/wire status vs iOS/mac | Trust status vs iOS/mac | Claim impact |
|---|---|---|---|
| iOS/mac (reference) | Supports `0x0001/0x0101/0x0102/0x1001/0x1002`, LE wire encoding, explicit no-timeout fallback + 5 min cooldown | Pinned trust + legacy fallback guardrails present | Baseline implementation |
| Android (`SkyBridge Compass - Android`) | Supports `0x0001/0x0101/0x0102/0x1001/0x1002`; `MessageA` parsing is forward-compatible; startup suite selection uses version-tier policy with explicit fallback cooldown guard | Shared handshake module exposes explicit pinned trust persistence/verification contract (`TrustStore` + `peer_signing_fingerprint`) | Interop/trust/cooldown warning and blocker items are closed at checker level |
| Ubuntu (`SkyBridge Compass Ubuntu`) | Supports `0x0001/0x0101/0x0102(parse-only)/0x1001/0x1002(parse-only)`; handshake negotiation now applies Ubuntu-version tier policy plus explicit per-peer fallback cooldown | Trust store + fingerprint pin check path exists (device-id keyed) | Suite-catalog + cooldown warning items are closed; `0x0102/0x1002` remain parse-only by explicit contract |
| Website (`SkyBridge-official website`) | Shows shared account/backend alignment (Supabase and NebulaID), not P2P handshake evidence | Not a transport-layer trust proof artifact | Useful external ecosystem evidence, not cryptographic interop evidence |

### Blocking gaps before claim upgrade (A/E high priority)
1. Interop blocker-level mismatches are closed in `check_cross_platform_interop.py` (status PASS).
2. Warning-level items are also closed (`cooldown_guard=PASS`, no residual warnings in report).
3. Paper wording can now describe policy-path parity as implemented, while keeping explicit caveat that `0x0102/0x1002` are parse-only compatibility markers on Ubuntu/Android.

## Step-2 execution record (2026-02-17, EC2 Linux)
Target: close the "external Linux evidence" priority first using a remote EC2 instance.

### Commands executed
```bash
# EC2 server
python3 ~/run_real_network_e2e_linux.py server --bind 0.0.0.0:44444

# local client (attempt 1: hostname)
python3 Scripts/run_real_network_e2e_linux.py client \
  --connect ec2-57-183-20-71.ap-northeast-1.compute.amazonaws.com:44444 \
  --label ec2_v2_contract --artifact-date 2026-01-23 --samples 50

# local client (attempt 2: public IP)
python3 Scripts/run_real_network_e2e_linux.py client \
  --connect 57.183.20.71:44444 \
  --label ec2_v2_contract_probe_ip --artifact-date 2026-01-23 --samples 5

# local client (attempt 2b: public IP on 443)
python3 Scripts/run_real_network_e2e_linux.py client \
  --connect 57.183.20.71:443 \
  --label ec2_v2_contract_direct443_probe --artifact-date 2026-01-23 --samples 10

# local client (attempt 3: SSH tunnel fallback)
ssh -fN -L 44445:127.0.0.1:44444 ec2-user@ec2-57-183-20-71.ap-northeast-1.compute.amazonaws.com
python3 Scripts/run_real_network_e2e_linux.py client \
  --connect 127.0.0.1:44445 \
  --label ec2_v2_contract_tunnel --artifact-date 2026-01-23 --samples 50

# local client (final direct run on production EC2 after SG ingress correction)
python3 Scripts/run_real_network_e2e_linux.py client \
  --connect 54.92.79.99:44444 \
  --label ec2_v2_contract_54_direct --artifact-date 2026-01-23 --samples 50
```

### Results
- `Artifacts/realnet_e2e_summary_2026-01-23_ec2_v2_contract.csv`:
  - `687B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
  - `12002B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
- `Artifacts/realnet_e2e_summary_2026-01-23_ec2_v2_contract_probe_ip.csv`:
  - `687B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
  - `12002B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
- `Artifacts/realnet_e2e_summary_2026-01-23_ec2_v2_contract_direct443_probe.csv`:
  - `687B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
  - `12002B`: `ok_rate=0.0000`, `timeout_rate=1.0000`
- `Artifacts/realnet_e2e_summary_2026-01-23_ec2_v2_contract_tunnel.csv`:
  - `687B`: `ok_rate=1.0000`, `total_p50_ms=192.826`
  - `12002B`: `ok_rate=1.0000`, `total_p50_ms=267.350`
- `Artifacts/realnet_e2e_summary_2026-01-23_ec2_v2_contract_54_direct.csv`:
  - `687B`: `ok_rate=1.0000`, `total_p50_ms=210.391`, `total_p95_ms=262.526`
  - `12002B`: `ok_rate=1.0000`, `total_p50_ms=225.216`, `total_p95_ms=334.648`

### Interpretation
- Interop contract path is functional end-to-end with remote Linux when transport path is guaranteed (SSH tunnel).
- Direct public TCP path is now also validated on production EC2 (`54.92.79.99:44444`) after explicit SG ingress alignment with the current client egress IP.
- Local resolver diagnostic at run time returned `ec2-57-183-20-71.ap-northeast-1.compute.amazonaws.com -> 198.18.0.134`, while EC2 IMDS reported public IP `57.183.20.71`.
- Direct probe on `443` also timed out without server-side accept logs, which rules out "single blocked test port" as the only cause.
- Final result is valid both as compatibility evidence and as direct-path external Linux evidence (for the tested source-IP/security-group conditions).

### Direct-path closure conditions (now satisfied in final run)
1. EC2 inbound TCP rule for `44444` explicitly allows current client public IP (`39.144.81.111/32` at run time).
2. Local resolver/routing reaches EC2 public endpoint directly (no transparent remap on this path).
3. Final direct run completed with `n=50` per payload and paired server-side accept logs.

## Risk-to-action matrix
| Risk | Current evidence | Gap | Planned actions | Exit criteria |
|---|---|---|---|---|
| A. External validity / representativeness | Realnet + kernel + simulation stack exists | Non-Apple quantitative evidence absent in submission package | Add cross-platform interop/perf dataset and table (`s13`), add main-text summary + CI; extend gate checks | At least 3 non-Apple pair-types, each with reproducible N and CI; claim wording upgraded from "future work" to "measured scope" |
| B. Novelty / transaction contribution clarity | C1-C3 + security contract already stated | Reviewer may still view as "engineering assembly" | Add "delta-to-prior-work" table + ablation-by-property table (what breaks if policy/audit gates removed) | Each contribution has a non-substitutable artifact-backed delta |
| C. Formal coverage and alignment | Tamarin lemmas for core policy properties | Missing explicit coverage of cooldown/bootstrap branches and implementation alignment map | Extend theory + add lemma set; add model-to-code traceability table; add concurrency stress artifact summary | New lemmas pass; traceability table covers every theorem-level claim |
| D. Security semantics hard edge (v1/v2 PFS) | v1 no-full-PFS language already present | Risk of wording drift and reviewer over-reading | Add claim guardrails (terminology lint), add security semantics matrix/time-line figure, tighten abstract/conclusion wording | No unqualified "forward secrecy" claims; v1/v2 semantics are unambiguous in title/abstract/body/conclusion |
| E. Baseline fairness | Baseline table includes policy/audit columns | Still vulnerable to "not same objective function" challenge | Add scenario-level comparison for forced downgrade/auditability semantics; keep latency/wire as secondary | Baseline section explicitly compares both security objective and cost objective |
| F. Threat boundary realism | Threat model + assumptions listed | Pairing social engineering, partial compromise, log-injection/privacy not stress-tested enough in text | Add boundary stress table + residual-risk handling runbook; add audit signal abuse cases and expected behavior | Boundary cases become explicit "in/out model" with concrete mitigations and failure handling |

## Workstreams (implementation-level)

### W1: Cross-platform evidence intake (A, E)
1. Add cross-repo consistency checker:
   - `Scripts/check_cross_platform_interop.py`
   - Inputs: iOS/mac + Android + Ubuntu source trees
   - Outputs:
     - `Artifacts/interop_consistency_2026-01-23.json`
     - `Artifacts/interop_consistency_2026-01-23.md`
   - Required checks:
     - suite ID catalog parity (including explicit handling contract for unsupported IDs)
     - LE wire encoding fields parity
     - sigA selection contract parity (`PQC -> ML-DSA`, `Classic -> Ed25519`)
     - fallback deny-list parity (`timeout` blocked) and cooldown/rate-limit parity
     - pinned identity/trust-path parity (present/absent + test coverage)
2. Close interop blockers in external repos (before paper claim upgrade):
   - Android:
     - make `MessageA` suite parsing forward-compatible for unknown future IDs
     - add explicit compatibility behavior for `0x0102`
     - add pinned-peer trust persistence + verification artifact/tests
   - Ubuntu:
     - keep explicit `0x0102` compatibility behavior (parse-only + contract-level reject/retry path) and preserve tests
     - close `0x1002` support stance and keep parser behavior auditable
3. Add new artifact schema file:
   - `Artifacts/interop_cross_platform_2026-01-23.csv`
   - Suggested columns: `initiator_platform,responder_platform,policy_mode,suite_mode,path_label,n,success_rate,p50_ms,p95_ms,delta_vs_classic_ms`
4. Add aggregator:
   - `Scripts/aggregate_interop_matrix.py` -> `Docs/supp_tables/s13_interop_matrix.tex`
5. Update supplementary index + optional include block in:
   - `Docs/TDSC-2026-01-0318_supplementary.tex`
6. Add one-paragraph main text summary in:
   - `Docs/tdsc_submission/paper.tex` (`sec:network-conditions` and limitations section)
7. Add gate checks in:
   - `Scripts/check_top_tier_gate.sh`
   - Require:
     - interop consistency report exists and no blocker-level mismatches
     - interop CSV has minimum platform-pair coverage
     - supplementary `s13` generated and referenced

### W2: Novelty hardening (B)
1. Add one compact "why this is not just TLS/Noise assembly" table in related-work section:
   - Policy-gated fallback contract
   - Event-minimal auditability contract
   - Mechanism-to-implementation traceability
2. Add ablation-by-property appendix table:
   - Remove timeout blacklist -> forced downgrade risk appears
   - Remove cooldown -> downgrade cycling risk appears
   - Remove event schema -> audit non-reproducible

### W3: Formal coverage upgrade (C)
1. Extend `formal/skybridge_v2.spthy` to model:
   - strict compliance vs bootstrap-assisted
   - timeout branch and fallback deny rule
   - cooldown gate events
2. Target new lemmas (names can be adjusted but must be explicit):
   - `TimeoutCannotTriggerClassicFallback`
   - `BootstrapControlOnlyUntilPQCRekey`
   - `FallbackRateLimitEnforced`
   - `DowngradeEventRequiredWithContext`
3. Regenerate artifacts:
   - `Artifacts/tamarin_skybridge_v2_*_2026-01-23.*`
4. Add model-to-code claim mapping table in supplementary.

### W4: Security semantics guardrail (D)
1. Add wording lint script:
   - `Scripts/check_claim_guardrails.py`
   - Block unqualified phrases (example: "forward secrecy" without v1/v2 qualifier)
2. Add security semantics matrix:
   - "attacker learns long-term KEM key at t1" vs "recorded session at t0"
   - v1 and v2 side-by-side outcome
3. Patch abstract/conclusion to keep language fully aligned with matrix.

### W5: Threat boundary stress pack (F)
1. Add "boundary stress cases" table (supp):
   - pairing social engineering
   - endpoint partial compromise (read-only vs signing capability)
   - audit-log injection/truncation/privacy leakage
2. Tie each case to:
   - expected event signatures
   - operator action (re-pair, quarantine, strict mode, retention policy)
3. Add explicit "what is out-of-model and why" paragraph in main security model section.

### W6: Writing and consistency sweep (low-risk polish)
1. Global claim-strength sweep in:
   - `Docs/tdsc_submission/paper.tex`
   - `Docs/TDSC-2026-01-0318_supplementary.tex`
2. Quantify limitations impact (not only list limitations).
3. Parameter rationale addendum:
   - `cooldown=5min` threat/availability tradeoff sensitivity with explicit bounds.

## Execution phases

### Phase 0 (0.5 day): Freeze claim envelope
- Lock approved claim dictionary and forbidden phrases.
- Ensure main/submission tex are identical via existing consistency script.

### Phase 1 (1-2 days): Interop blocker closure (A/E mandatory)
- Implement `check_cross_platform_interop.py` and produce first consistency report.
- Close Android/Ubuntu blocker items from the report.
- Re-run consistency report until blocker-level mismatches are zero.

### Phase 1.5 (1 day): Cross-platform evidence integration
- Integrate Android/Ubuntu dataset.
- Generate `s13` interop table and add main text summary.
- Update gate script with platform-coverage and interop-consistency checks.

### Phase 2 (1-2 days): C/D closure
- Extend Tamarin + regenerate proof artifacts.
- Add semantics matrix and guardrail lint.

### Phase 3 (1 day): B/F + writing pass
- Add novelty delta/ablation table.
- Add threat boundary stress table and residual-risk text.
- Run full consistency and compile checks.

### Phase 4 (0.5 day): Submission gate
- Re-run full gate, compile PDFs, final checklist sign-off.

## Command checklist (existing)
```bash
cd "/Users/bill/Desktop/SkyBridge Compass Pro release"
ARTIFACT_DATE=2026-01-23 bash Scripts/run_paper_eval.sh
python3 Scripts/make_tables.py
ARTIFACT_DATE=2026-01-23 bash Scripts/check_paper_consistency.sh
ARTIFACT_DATE=2026-01-23 bash Scripts/check_top_tier_gate.sh
bash ./compile_paper.sh
```

## New scripts planned in this plan
- `Scripts/check_cross_platform_interop.py`
- `Scripts/aggregate_interop_matrix.py`
- `Scripts/check_claim_guardrails.py`

## Immediate dependency (for A closure)
Need Android/Ubuntu experiment artifacts to be placed into this repo (or symlinked) using a stable date suffix (`2026-01-23`) so they can enter the same reproducibility pipeline and top-tier gate.  
In parallel, keep external source paths stable for consistency checks:
- `/Users/bill/Desktop/SkyBridge Compass - Android`
- `/Users/bill/Desktop/SkyBridge Compass Ubuntu`
- `/Users/bill/Desktop/SkyBridge-official website`
