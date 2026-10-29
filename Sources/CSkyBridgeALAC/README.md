# ALAC packet decoder and Apple SDK

The source-locked Apple SDK is registered in `SkyBridgeAudioFile`, with a sequential Swift owner,
complete file validation and bounded PCM reads. The Mac original-file receiver now advertises
`audio_alac_file_receive_v1` only with its installed consumer and a usable file route. The Android
original-file sender negotiates that capability and sends the committed encoded bytes unchanged.
**These implementation/component results do not establish physical phone or output acceptance.**
Native execution is qualified on macOS arm64; iOS slices and Swift callers compile/link but have
not executed on those targets. iOS app sender integration and Android/Windows native ALAC decoding
remain open. Android original-file transfer does not require a local ALAC decoder.

## Boundary

The owner supplies the original 24-byte ALACSpecificConfig, finite packet/frame totals, and one
compressed packet at a time from its held, commitment-verified source. Each packet's expected
frame count comes from the validated container time table. The decoder does not open files,
parse containers, perform network I/O, negotiate authorization, or access output hardware.

Supported candidate precision is 16/20/24/32 valid bits, mono or stereo. Output is interleaved
little-endian signed integer PCM, with high-aligned valid bits in the smallest 16/24/32-bit
container. No resampling, gain, channel remapping, float conversion, error concealment, or
format fallback is applied. Per-packet frame/byte bounds and cumulative counts are checked.

The caller must serialize operations and destruction. The borrowed cancellation/authorization
callback cannot reenter or destroy this decoder; a language-level owner must defer reentrant
close requests. Cancellation is checked before and after native decoding, during output copy,
and before committing a successful result. On any error, the result exposes zero output bytes,
native resources are released, and failure remains sticky. Callers must discard all output
storage on failure, including partially written storage. Only a complete declared sequence and
a clean native EOF may produce completion. Destruction of the remaining opaque handle is still
required after failure or completion.
Initialization failures preserve the native error code and distinguish allocation, provider,
source-declaration, and negotiated-format failures.

These checks do not replace held-file identity checks, grant/session ownership, packet indexing,
or the owner's synchronization and lifetime rules. The Apple container/index, held-reader factory
and sequential native owner have the bounded evidence below; the complete playback route remains open.

## Provider and source lock

`source-lock.json` pins the official FFmpeg 8.1.3 archive, detached signature, release public key,
patches, and license files. The release signature was verified against primary fingerprint
`FCF986EA15E6E293A5644F10B4322F04D67658D8`. The key was obtained from the official HTTPS endpoint;
this is not an independent transparency or reproducible-build attestation.

The recipe enables only the ALAC decoder in libavcodec plus libavutil. Container libraries,
network protocols, resamplers, encoders, capture/output runtimes, GPL/nonfree/version-3 options,
and automatic external libraries are disabled. The qualified macOS build depends only on the
two provider libraries and libSystem, with no Homebrew runtime or Apple media framework links.

The strict-error patch retains native errors under `AV_EF_EXPLODE` where upstream otherwise:

- Logs and clamps a zero run exceeding the packet's advertised samples.
- Logs excess data after an end element but returns a frame.
- Can discard an element error when the bit reader has no bits left.
- Can report missing channels without returning an explicit invalid-data error.

The bridge always enables strict error recognition. An additional provider-contract symbol
prevents accidental linkage to an unpatched ABI-compatible library. This marker does not
replace source, artifact, dependency, or signing verification.

The separate build patch fixes a narrowing function-pointer cast in a configure probe, removes
an obsolete Darwin linker flag, limits library search paths to enabled components, detects
system math symbols before adding a separate library, and honors disabled autodetection for
unused Apple frameworks. It does not turn off compiler/linker warning failures. Initial
configuration, linking, and dependency-gate failures remain in the qualification evidence.

## Reproduction and evidence

Run `Scripts/audio_alac_qualification/build_provider.py` with the archive, detached signature,
key, a new work directory without spaces, and a new evidence directory. It runs one build job,
verifies the source and patch hashes, bounds extraction, and checks components, architecture,
dynamic dependencies, and licenses. It never installs globally or replaces an existing run.
`--baseline` uses the same build fixes and flags while omitting the decoder patch.

`qualify_bridge.py` takes the baseline/strict build-receipt directories, the real encoder fixture
directory and a new evidence directory. It checks provider hashes, freezes the C boundary,
compiles both packet probes, tests unqualified-provider link rejection, runs `check_bridge.py`,
and invokes the native static analyzer. `RawPacketProbe.c` and `packet_fixtures.py` provide the
old/new counterexamples. Exact commands and frozen sources are retained at
`artifacts/alac-decoder-integration-20261025/clean-qualification-final/commands.json`.

The initial runs inherited local CPATH and LIBRARY_PATH overrides. Their evidence remains, but
the final provider builds and qualification explicitly remove ambient compiler, header, linker,
dynamic-loader and make overrides and select the SDK. The final receipt records the removed
variable names. This bounds the development-environment dependency; it is not a hermetic or
cross-host reproducible-build attestation.

The 2026-10-25 results are:

- Both matched provider builds complete with zero compiler/linker warnings; only ALAC is enabled.
- 24 real ALAC files at 44.1/48/96 kHz, mono/stereo, and 16/20/24/32 valid bits match the independently
  generated integer PCM references byte for byte, including low bits and final partial packets.
- 53 C ABI cases pass, including cancellation before publication and during copy, source/packet
  limits, count disagreement, incomplete EOF, sequence errors, and sticky failure.
- With the same build recipe, unpatched decoding accepts both the invalid zero run and excess
  trailing data, returning eight frames without frame-error flags. Patched decoding rejects both.
- The product bridge refuses to link against the unpatched provider despite the matching 8.1.3 ABI.
- The frozen C boundary's native static analyzer reports zero diagnostics.

This is bounded qualification. It does not prove arbitrary malformed inputs are detectable,
memory safety of the complete third-party library, or cross-platform sample equality.

## Apple container and held-source declarations

The Apple `AudioAlacFile` inspector now validates the finite M4A/MP4 profile and provides a
paged `stts`/`stsz`/`stsc`/`stco`/`co64` cursor. Inspection walks the declared packet sequence
without decoding or reading compressed packets. Packet ranges, counts, durations and metadata
resource limits are checked, including the final partial packet. `AudioIndexedAlacFile` binds
these declarations to the caller's existing `PreparedOutboundFileReadSession`; it does not
reopen the path, take over file ownership, produce a decoded-file witness, or grant playback.

`artifacts/alac-file-session-20261025/metadata-tests-04/` records 17 passing XCTest methods over
actual source snapshots, Swift 6 strict concurrency and warnings as errors. These include all
24 real-file packet indexes compared with independent demuxer output, 30 invalid declarations,
paged tables, truncation, exact EOF, retained-descriptor path replacement, closed readers,
source mutation, authorization failure and cancellation. A controlled negative variant that
omits the post-authorization cancellation check fails the final-callback test; this is a
counterexample to that omission, not a claim about a previously shipped product. The actual
`SkyBridgeAudioFile` package target also builds with frozen dependency resolution, with zero
reported warnings/errors. Commands, source hashes and failed initial harness attempts remain
in the same evidence directory. The actual source dependency closure also emits/typechecks for
iOS arm64 and both arm64/x86_64 simulator SDK targets (six checks), under the same strict Swift
settings. This does not replace native codec SDK builds, full application or iOS device testing.

The 24 generated M4A files and packed PCM references are reproducible through
`Scripts/audio_alac_qualification/export_decoder_fixtures.py`. All 49 repository files,
including the manifest, matched a fresh export byte for byte. They contain deliberate sample
extremes for byte comparison and are not listening-test signals.

## Apple SDK and Swift owner increment, 2026-10-25

`Sources/Vendor/alac.xcframework` contains macOS arm64, iOS arm64 and a combined arm64/x86_64
iOS simulator framework. The codec objects are private inside a dynamic `CSkyBridgeALAC`
framework; only its six `sbalac` entry points are exported. Its only external native dependency
is libSystem. Each SDK/architecture has a separate configuration and one build job; no simulator
objects are substituted for device objects. Native compilation/linking reported zero warnings.

The official signed release was compared with its pinned Git tag: 10,115 common files match;
only Git ignore/attribute files and the generated release `VERSION` differ. The archive, public
signature/key, patches, C bridge, headers and slice build scripts are retained in
`Sources/Vendor/NativeSources/alac`, with notices in `NativeLicenses/alac`. This is signed-source
verification and a local deterministic provenance record, not an independently attested build.
Official source and verification guidance: [FFmpeg downloads](https://ffmpeg.org/download.html).

`Scripts/audio_alac_qualification/build_provider.py --apple-slice <profile>` builds a new slice;
profiles are `macos-arm64`, `ios-arm64`, `ios-simulator-arm64`, `ios-simulator-x86_64`.
`Scripts/build_alac_xcframework.py` takes all four receipt directories, the pinned Git checkout
and archive/signature/key, verifies them, and produces a new staged candidate. It checks every
final thin slice against its qualified input bytes. It never overwrites live Vendor artifacts.
The final candidate and admission receipts are in `artifacts/alac-apple-sdk-20261025/package-03/`
and `sdk-admission.json`; the live SDK is bound by `Sources/Vendor/alac.provenance.json` and the
`alac` family in `Config/native-dependencies.lock.json`.

The shared provenance verifier now inventories flat dynamic frameworks and inspects each
architecture's install name/dependencies separately. The real first universal package exposed
the former single-architecture assumption and remains as failed evidence. Thirty provenance
tests pass, and the existing libFLAC, liboqs and FreeRDP records still verify.

The first Swift consumer linked but failed to launch because it lacked a runtime search path.
Executable consumers now own their macOS adjacent-framework and app-bundle relative paths;
XCTest retains its supplied path instead of receiving duplicate library-level flags. This follows
[Apple's run-path model](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/RunpathDependentLibraries.html).
The corrected consumer and a separately relocated app bundle execute without user-supplied loader
paths. iOS arm64 and both simulator callers also compile/link; they were not run on a device.

`AudioAlacPCMDecoder` uses the indexed file's existing reader, exact packet durations and one
bounded PCM frame per call. It preserves native/source/authorization failures, rejects overlapping
reads, rechecks cancellation after the reader actor returns, and serializes native destruction.
Reentrant callback close defers freeing the C owner until that native call exits. It does not
close the caller's reader or turn a decoded prefix into a validated file/playback permission.

`audio-owner-tests-03/` has 25 passing focused XCTest methods with zero warnings: the prior 17
container/reader tests plus eight native-owner methods. All 24 generated files match exact PCM
through this Swift path. Negative cases cover missing native output, revocation, cancellation,
reentrant close, concurrent reads, reader mutation/close, path replacement and sticky failure.
The actual `SkyBridgeAudioFile` target builds, and the owner/dependency source closure passes
six iOS device/simulator compilation checks. The Mac framework also passes all 53 C ABI cases.
Neither suite opens an output device or tests an authenticated phone connection.

The subsequent validated-file component qualification is recorded in
`artifacts/alac-file-validation-20261025/receipt.json`. `AudioValidatedAlacFile` decodes and
discards the entire committed source under a 180-second deadline before constructing a witness.
`AudioValidatedPCMReadSession` supplies bounded sequential PCM for ALAC and FLAC; the original
FLAC type name remains a source alias. Cached PCM still requires current source ownership and
authorization. Terminal errors discard the pending frame and close the decoder, while the outer
owner retains the reader. Fifty-six focused XCTest methods pass, including all 24 exact ALAC
references, corrupt-final-packet rejection, deadlines, revocation, cancellation and read sequencing.
Restoring the actual previous FLAC validation/adapter source in an isolated snapshot reproduces
two final-callback cancellation failures; the corrected implementation passes those regressions.
The actual audio target builds and all six iOS device/simulator source checks pass without warnings.

The Mac original-file receiver integrates this witness and the existing exact-format playback
pump. ALAC is fully decoded before output preparation; malformed tail packets fail without
opening output. Both real encrypted loopback-file and USB epoch-multiplex paths preserve exact
source PCM through an explicit substitute output. The four-frame test output reports its one
trailing padding frame separately from the 4,427 ALAC source frames. No sample is added to the
source count. All 155 selected root-package XCTest methods pass with zero warnings; see
`artifacts/alac-original-file-integration-20261025/apple-tests-03/`.

The initial root run retained an old embedded test-resource bundle that shadowed the current
generated bundle. Its missing ALAC fixtures and original failure are preserved. The corrected
run uses SwiftPM's documented generated accessor override for the current build-products path;
all 49 ALAC fixture files match the source hashes. Executable rpaths now use `@executable_path`
for adjacent frameworks, avoiding the loader path that XCTest adds to executable products.

iOS app sender integration, physical phone/background/output acceptance and native ALAC decoding
on Android/Windows remain open. Existing strict output checks are unchanged; a mixable-only
advertised output is still refused by the current strict policy.
The provider uses LGPL-2.1-or-later under this configuration; the recipe preserves the full
license notices. Source/relinking and platform distribution obligations must be satisfied by the
actual deliverable. No global license, product signing policy, or existing audio policy is changed.
