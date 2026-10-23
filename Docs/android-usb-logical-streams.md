# Android USB logical streams: Apple integration

Status, 2026-10-23: shared Swift wire/state implementation and Kotlin/Swift
process interoperability verified. Native Mac byte and multiplex owners now have
focused lifecycle checks and Kotlin process interoperability. Their current
physical data transfer, authenticated product admission and audio integration
remain open. No new USB capability is advertised.

The existing `SkyBridgeCore.USBMultiplexTransport` speaks Apple's usbmuxd
protocol. It stays the Apple-device route; it is not an Android AOA implementation.
The new `SkyBridgeProtocolCore.USBLogicalStreamWire` and
`USBLogicalStreamProtocol` implement the bounded Yamux v0 contract used by the
Android carrier. They add no Network.framework, IOKit, account or cryptographic
runtime to the shared protocol layer.

## Ownership contract

One protocol object belongs to one physical attachment generation. It serializes
protocol transitions with a private lock, without performing I/O, callbacks or
waits inside that lock. Default limits are eight retained owners, two pending
accepts, 4,096 non-reused identifiers and 32 session control frames. Each stream
has a fixed 256 KiB receive window and one pending write of at most 16,372 bytes;
the twelve-byte header keeps an outgoing wire frame within a 16 KiB transfer.
The receive ring is updated without retaining a second dictionary alias that
would force a full-window copy on each frame. This is a storage/ownership
property, not a measured memory, CPU or USB throughput claim.

`pollOutbound` commits exactly one immutable dispatch token. Only its matching
completion can finish it. `written` means local native dispatch, never peer
receipt. Reset fails both logical directions; releasing an owner waits for its
committed dispatch and reset. Before native I/O starts, only the exact retired
DATA dispatch can be discarded. Physical failure retires all streams and never
becomes a normal per-stream FIN. Half-close preserves the reverse direction.
Late frames remain bounded by both count and outstanding credit. Current ping
replies must match a dispatched, strictly increasing challenge; they grant no
identity, account validity or playback permission.

The native byte and multiplex owners described below supply reader/writer lifetime,
whole-frame deadlines, attachment checks and silent-peer expiry. Authenticated
purpose admission remains an explicit integration gate. The protocol object has no timer and
cannot certify a driver or worker has stopped. It must feed the existing
PIB/SKR, MAIN/Finished and authenticated file/audio paths, without a local TCP
forwarder, fake IP endpoint, new trust store or crypto fallback. Strict original
format output remains unchanged.

## Reproducible checks

From this repository, with the selected Xcode installed:

```sh
python3 Scripts/check_usb_logical_streams.py --output /absolute/new/evidence-directory
```

The script builds the actual `SkyBridgeProtocolCore` target with one build job,
Swift 6 and warnings as errors. It links the focused XCTest suite and local peer
against the current aggregate module object, with linker warnings treated as
errors. It does not copy protocol sources into a parallel package. A legacy
`libSkyBridgeProtocolCore.a` may coexist in Products; it is not used as evidence
for the completed target. The initial manual link encountered such a stale
archive, and that failure is retained in the local record. The script also uses
Xcode's Swift XCTest overlay, rather than only the Objective-C framework headers.

Twenty XCTest cases cover header vectors and malformed frames, bounded credit
and queues, wrapped/tiny receive frames, sliced input ownership, identifier
reuse, half-close, reset, physical failure, late data, go-away, exact dispatch
completion and matching liveness challenges. Test discovery and execution
counts must match the checked-in test methods; no test is skipped.

The produced `swift-yamux-peer` is a test executable, outside product targets.
It listens for exactly one connection on 127.0.0.1, has bounded waits, emits byte
and hash receipts, and confirms its reader exit after closure. It is not a
native USB adapter. In the Android repository, select it explicitly:

```sh
./gradlew --no-daemon --no-configuration-cache --max-workers=1 \
  -I scripts/audio_usb_probe/stream_reference/interop.gradle \
  -PusbYamuxReferencePeer=/absolute/verified/yamux-reference-peer \
  -PusbYamuxSwiftPeer=/absolute/new/evidence-directory/swift-yamux-peer \
  :core:testDebugUnitTest --tests '*UsbYamuxReferenceInteropTest' \
  --tests '*UsbYamuxAppleInteropTest'
```

Quote each complete `-P...` argument when its path contains spaces. Both peer
executables are registered as Gradle test inputs, so replacing one invalidates
cached test results. The Apple fixture verifies the Swift implementation marker
and its final cleanup receipt; a missing peer does not fall back or skip.

Six Kotlin↔Swift cases passed: protocol-state and actual Android pump variants
each cover a blocked file window with a separate control exchange, a 262,145-byte
echo, reverse early data with a 65,579-byte echo and FINs, and reset followed by
another stream. Both sides and an independent digest agree. The six official Go
reference cases remain separate; their known late-credit warning is preserved
and has an official-to-official reproduction in the Android experiment.

The two new shared Swift files also pass an ARM64 iOS 17 source type check with
the installed device SDK. This is not an iOS app build, installation or runtime
test. Mac and iOS product builds, physical AOA, Samsung driver coexistence,
consumer startup without ADB, account/offline grants and original-format audio
acceptance remain independent gates. Q-Periapt was not upgraded.

Local evidence is under the Android workspace's
`artifacts/apple-usb-logical-streams-20261023/`. Existing Apple working-tree
changes were preserved; only the new protocol, focused test, peer, check script
and this integration record belong to this addition.

## Native Mac byte owner

`SkyBridgeAppleTransport.USBHostByteTransport` owns one reader, one writer and a
cleanup supervisor. `CSkyBridgeUSBHost` is a narrow macOS-only IOKit dependency;
it is not introduced into `SkyBridgeProtocolCore` or the iOS dependency graph.
The C boundary opens only the selected current registry entry in AOA accessory
mode (`18d1:2d00` or `18d1:2d01`), interface zero, with one bulk endpoint in each
direction. It uses ordinary public IOUSBLib190 operations. It does not seize,
switch USB modes, reset the device, stop a service, disable another driver or
fall back to a network endpoint. Registry IDs and descriptors are not identity.

Raw reads always provide a 16 KiB native buffer and retain its unused tail.
Successful zero-length USB transfers are packet boundaries, not EOF; they do
not extend the operation deadline. Writes are bounded to 16 KiB, preserve the
exact supplied bytes and check captured effect authority before and after the
native operation. A failed `WritePipeTO` has no known partial byte count and is
never retried as an unwritten packet. Attachment/authority callbacks must be
bounded, thread-safe and non-reentrant.

Cancellation retires C admission before waking the supervisor. The caller is
not blocked on native abort/close. The supervisor waits for the actual reader
and writer `Thread.isFinished` states before release. Opening that completes
after cancellation never becomes ready. The observer's bounded cleanup wait
does not terminate or abandon an unresolved native call. `shutdownState`
exposes retirement, actual worker exit, reference release and cleanup error as
separate facts. A native close error remains visible after COM reference release;
an unconfirmed `IOObjectRelease` leaves the owner unresolved. No automatic
release retry guesses whether the reference is still valid. Idle ownership has
no fixed polling timer; active deadlines are checked against the current request
under the same lock as completion/admission, so an old snapshot cannot expire a
new request.

Run focused checks serially:

```sh
python3 Scripts/check_usb_host.py --output /absolute/new/native-evidence-directory
```

The script builds the real C and Swift targets. Fourteen C cases run separately
with address/undefined-behaviour and thread sanitizers. Sixteen Swift cases run
against the actual thread-sanitized `SkyBridgeAppleTransport`, protocol and C
objects; the script verifies instrumentation, input hashes and exit statuses.
They exercise cancellation during acquisition and I/O, simultaneous directions,
bounded admission, sliced writes, packet tails/ZLP, attachment and effect
revocation, replaced deadlines, close errors, unresolved cleanup and deinit.
Native registry-absence checks use the real IOKit boundary. These tests inject
native outcomes and do not establish physical device data behaviour.

Local evidence is in the Android workspace's
`artifacts/apple-usb-native-carrier-20261023/`. A separate negative check selected
the actual USB-connected Samsung phone while it remained in normal
charging/ADB mode: it was rejected as not an accessory, and the Swift owner
confirmed worker exit/reference release. No USB mode, permission, driver, app
installation or playback setting was changed. SamsungAOA remains enabled; the
earlier physical ordinary-open conflict is still an open integration gate.
The earlier successful experimental AOA transfers are not proof for this new
carrier. An actual current-carrier round trip, PIB/SKR/MAIN consumers, launch
without ADB and authenticated audio remain pending.

## Native multiplex lifecycle

`USBHostMultiplexConnection` connects the shared protocol to the actual
`USBHostByteTransport`. A single reader pump keeps one whole-frame deadline
across header/body reads and validates the header before allocating its body.
A single writer pump binds each committed DATA dispatch to its captured write
lease. One event-driven deadline task owns pending-accept, half-close and current
ping expiry; audio data does not renew the liveness challenge. Matching pings
prove only transport progress, not identity or account validity.

Public stream operations allow one reader and one writer. The existing four-byte
big-endian control framing and 1 MiB policy ceiling are reused. One read lease
covers both prefix and body, so a second caller cannot interleave frame parsing.
Large writes split into bounded wire frames and wait for credit and their exact
dispatch completion within the original deadline. They preserve the supplied
bytes; `written` remains local dispatch evidence, not a peer file/audio receipt.

Revocation before native dispatch discards only that exact retired DATA frame
and resets its logical stream. Once raw writing is entered, a failure retires
the physical connection because bytes may already have left. The original
authority failure is published before native cleanup can block or another
reader reports a secondary disconnect. FIN preserves the reverse direction;
physical EOF is never synthesized as a successful logical FIN. Cancelled reads,
credit timeouts and pending/half-close expiry do not implicitly cancel siblings.

Dropping a public stream view resets it and transfers cleanup to the connection;
the handle table does not keep the view alive in an ARC cycle. Removed owners
still wake their registered cleanup observers. Connection cleanup waits for
native reference/worker evidence, actual pump task completion and logical
operations, with one cleanup observer at a time. A timed-out observer retains
unresolved ownership. The lifetime helper coalesces notifications, removes only
the exact cancelled waiter and joins the losing timeout/notification task.

```sh
python3 Scripts/check_usb_multiplex.py --sanitize --output /absolute/new/multiplex-evidence-directory
```

Twenty cases pass against the actual thread-sanitized native-byte, multiplex and
protocol modules. They include a 600,007-byte framed body, a blocked 700,011-byte
bulk write while a sibling control stream remains usable, scoped read/write
timeouts, queued/native revocation, reverse FIN, pending/half-close expiry,
dropped views, partial-frame EOF, ping expiry, cancellation during open/accept,
concurrent parent/stream cleanup, notification reuse, oversize headers and close
errors after confirmed release. Native I/O in these cases is a bounded synthetic
pipe; they are not physical USB or audio acceptance.

The same check script builds `swift-yamux-native-peer`, an isolated loopback
fixture that substitutes only native acquisition/I/O beneath the real byte owner
and pumps. Select it in Android with the additional argument
`-PusbYamuxSwiftNativePeer=/absolute/evidence/swift-yamux-native-peer` and run
`UsbYamuxAppleNativeInteropTest`. Its executable is a Gradle test input; there is
no fallback to a different peer. Six native-owner cases and six official Go
reference cases pass. The 262,145-byte and 65,579-byte echoes and 23-byte control
receipt agree with independent SHA-256 recomputation. Native-owner cleanup must
report worker exit, reference release, pump completion and zero logical owners.
Reverse tests prove data/FIN exchange; the native owner's public open waits for
ACK, so those cases do not add an early-DATA-before-ACK claim.

The first cross-language attempt failed its two reset cases. Kotlin's immediate
reset can clear a pending ACK and send RST directly; the old state-only fixture
returned a stream ID immediately, whereas the native owner's open waits for ACK.
The new fixture originally caught RST only in the later read. It now requires
an explicit RST during open or read, confirms the old owner is released, and
verifies the next stream's bytes/FINs. Both final reset receipts identify `open`.
No product admission, protocol validation or failure assertion was relaxed.
The failed receipts and matching candidate are retained separately.

Evidence is under `artifacts/apple-usb-multiplex-lifecycle-20261023/` in Android.
The expanded Android test-source lint run retains the same 125 errors and two
hints, compared by issue ID, message and source location; no new issue was added.
That existing lint debt, fresh published-branch/full-app builds, current physical
AOA data and the product authentication/file/audio consumers are not qualified
by these focused checks. Existing worktree changes and strict output policy
remain intact; Q-Periapt is unchanged.
