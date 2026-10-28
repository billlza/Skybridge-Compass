# BoundSession native dependency

The checked-in `Sources/Vendor/boundsession.xcframework` is required by the `BoundSessionFFI` binary target in
the root Swift package. Keep all three framework slices, their headers, relative
macOS framework symlinks, signatures and provenance together. The payloads must
be available in a clean Git checkout; they are not disposable build caches.

BoundSession binds session authority and file-operation grants to their owners.
The additive ABI v6 exposes protected initialization and restoration, including
intent, anchor and activation records and public-key digest binding. ABI refers
to the C function/structure contract shared by the native Rust implementation
and Swift callers. It is independent of the Q-Periapt SDK release version.

Supported slices are Apple Silicon macOS, arm64 iOS devices and arm64 iOS
Simulator. From the product repository root, validate the complete dependency:

```sh
python3 Scripts/verify_boundsession_xcframework.py
```

The gate checks 83 exported functions, including nine ABI-v6 functions, exact
headers and binary hashes, per-platform C layouts, install names and signatures.
Do not replace the binary with a library built against a different ABI header.

`SkyBridgeBoundSessionProvenance.json` retains the original source manifest and
development classification. Its `source_worktree_clean: false` is intentional
evidence of that build; adding these existing payloads to Git does not make its
source a qualified release. `--require-publishable-source` remains a separate
release gate. The integration signatures are ad hoc; shipping apps must apply
their own valid signing identity.

The existing rebuild recipe is `Scripts/build_boundsession_xcframework.sh`.
It accepts `--source-root` for the matching
`Research/PolicyPurposeBoundSession/implementation` source checkout. Rebuilding
also needs that source workspace's pinned Rust toolchain and dependencies;
ordinary product compilation consumes this XCFramework directly.
