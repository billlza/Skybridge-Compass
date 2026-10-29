# rtc 0.21.1 — SkyBridge patched copy

Based on the crates.io `rtc 0.21.1` release (archive SHA-256
`4e2ca201de5ccc83aa3c08d49a2f08d7ed0aeeb2052fb1ccc517a8b77a6927ce`,
upstream commit `2a732df55ca4bcf26b80914fa0f570cfaf74cfcb`). Source files are
unchanged except for the two files described below and one trailing-whitespace
cleanup in the RFC documentation list in `src/lib.rs` and a final blank line
removed from `docs/sans-io-deterministic-time-allowlist.txt`. The unused upstream
Cargo.lock is omitted; the application uses rust/Cargo.lock.

Version 0.21.1 moves DTLS curve arithmetic behind native crypto providers,
removing the old crypto-bigint 0.5 dependency affected by RUSTSEC-2026-0387.
The default ring provider is retained. The existing selected-route fix is
still needed in this stable version.

## The defect

Peer-reflexive ICE candidates are created inside the ICE agent
(`rtc-ice`, `Agent::set_selected_pair` path) and never pass through
`add_ice_local_candidate` / `add_ice_remote_candidate`, which are the only
call sites that register `LocalCandidate` / `RemoteCandidate` stats entries.
When the nominated pair's remote is peer-reflexive — the common case whenever
a STUN binding request arrives before the peer's signaled candidates, which
loopback and fast LANs hit almost always — `get_stats` reports a selected
pair whose `remote_candidate_id` resolves to nothing.

SkyBridge's native transport gates session readiness on observing the
selected route from genuine `get_stats` evidence. With this defect the
observation can never complete, the 5-second observation window lapses, and
every fresh Rust-agent session is torn down while the encrypted transport and
handshake are already healthy.

## The fix

`src/peer_connection/internal.rs`, `update_ice_agent_stats` (already invoked
by `get_stats` before every snapshot): register the selected pair's local and
remote candidates into the stats accumulator if absent, under the same keys
the normal registration paths use. Two `contains_key` probes are added to the
accumulator (`src/statistics/accumulator/mod.rs`) so richer existing entries
are never overwritten.

Grep for `SKYBRIDGE PATCH` to find every modified line.

## Retiring this patch

Upstream `rtc 0.21.1` still omits these candidate registrations. When a stable
release registers prflx candidates (or otherwise makes the selected pair's
endpoints resolvable from `get_stats`), delete this directory and the
`[patch.crates-io]` entry, and confirm
`skybridge-core native_webrtc::tests::selected_ice_route_is_observed_on_a_real_loopback_pair`
still passes — that test pins the behaviour against a real loopback pair.
