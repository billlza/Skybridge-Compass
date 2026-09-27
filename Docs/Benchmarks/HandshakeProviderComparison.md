# Full handshake provider comparison

`HandshakeBenchRunner` executes the production `HandshakeDriver` on two peers
connected by deterministic in-memory transports. The `comparison` profile selects
Q-Periapt ABI2 ContextBound, Apple CryptoKit ML-KEM-768, and Apple CryptoKit X-Wing.
All three use the production protocol signature selector and fresh Apple
ML-DSA-65 signing identities. Each peer has its own benchmark-local KEM identity
store; the exact remote signing public key is pinned before measurement.

Q-Periapt verifies the compiled public production policy and runs native ABI2
admission in the isolated benchmark process. Its temporary trusted-state store is
in memory; it does not enroll the application's Keychain or demonstrate durable
policy persistence. Signing/KEM identity setup, policy verification, admission,
and warmup occur before the recorded samples. No private keys are recorded.

## Build and smoke check

Run from the repository root on a supported Apple PQC host:

```sh
. Scripts/apple_pqc_sdk_probe.sh
skybridge_require_apple_pqc_sdk_symbol_probe macosx
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
swift build --product HandshakeBenchRunner -c release -Xswiftc -warnings-as-errors
SB_ENABLE_QPERIAPT=1 SKYBRIDGE_BENCH_PROFILE=comparison \
  SKYBRIDGE_BENCH_ITERATIONS=6 SKYBRIDGE_BENCH_WARMUP=1 \
  ARTIFACTS_DIR=/absolute/path/to/new-study \
  .build/release/HandshakeBenchRunner
```

Six measured rounds are a functional smoke check, not statistical performance
acceptance. The runner requires all three providers and equal sample counts.
There is no fallback to a smaller comparison. Each six-round block traverses all
six permutations of the provider order; incomplete blocks remain visible in the
raw data and must not be described as balanced. Register sample count, warmup,
batches, load conditions, source/SDK/compiler identity, and acceptance criteria
before a formal measurement. Do not replace failed or noisy runs until green.

## Evidence and measurement boundary

Each invocation prints a fresh `handshake-<UUID>` directory containing:

- `configuration.json` and `scope.json`: selected parameters and measurement scope.
- `samples.jsonl`: ordered raw samples, provider, suite, batch, round, latency,
  protocol RTT, and every sample's wire sizes.
- CSV summaries with the existing column and percentile conventions.
- `completion.json`: emitted only after every requested sample and summary is
  written successfully.

The timer spans `initiateHandshake` through its Finished completion, including
the deadline task group; it excludes driver construction, output, and teardown.
The runner then requires both drivers to be established with the requested suite,
matching transcript and directional keys, and authenticated remote authorities.
Exactly MessageA, MessageB, and both Finished frames must have been sent. A
measurement, provider, or artifact error exits nonzero. The incomplete run and its
raw data remain; no completion record means no successful run.

Protocol RTT here is an in-memory measurement, not network RTT. This experiment
does not measure cold identity generation, durable enrollment, network behavior,
concurrency capacity, physical devices, or cryptographic security. Padding and
nonce settings must be declared and controlled in the study; normal production
randomness should be used for product comparisons. Statistical summaries alone
are not an external performance acceptance proof.

The `core`, `contrast`, and `full` profiles retain the existing date-based CSV
outputs for paper scripts, in addition to the new per-invocation raw directory.
The `comparison` profile only writes inside its new directory and never appends
to legacy paper results. Output errors propagate, including errors writing a
legacy aggregate. Existing consumers must not treat an old CSV as proof that a
new invocation completed.

## Validation

`HandshakeBenchRunnerTests` covers invalid configuration and statistics, balanced
ordering, output isolation and failure propagation, transport ownership/closure,
and deadline cancellation of a suspended operation. Run with:

```sh
SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1 \
  swift test --filter BenchmarkContractTests -Xswiftc -warnings-as-errors
```

The Apple SDK override is valid only after the symbol probe above succeeds.

Use the default Debug test configuration: existing runtime tests rely on their
DEBUG-only hooks. The Release executable above is built and smoke-tested
separately, with those test hooks absent.
