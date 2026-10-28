# Audio streaming contract v1

Status: implementation in progress. The Mac app installs an inbound MAIN playback consumer
after its approval presenter starts. The installed shared consumer independently advertises
capture and original-file reception. Android now projects both explicit capabilities onto its
device action and shares one foreground-operation owner across the two source modes. The
original-file picker, cancellable provider source and core sender are connected in the debug APK.
Complete cross-platform and strict-output acceptance remains open; the scoped Bluetooth
device results below do not establish those paths.
The actual Mac classic receive socket branch is covered by isolated loopback tests with synthetic
session authority and native-output fixtures. This does not establish physical interoperability.
Strict original-format physical output remains unverified on the available hardware.
Scope: mobile to desktop original-file playback and system-captured PCM.

The explicit Opus Bluetooth extension below has structural codecs, a bounded decoder/output
consumer and opt-in integration into the existing Mac receive session. Default product startup
does not enable or advertise it. A signed local candidate completed one 600-second, 128 kbps
iPad-to-Mac file run using the negotiated buffered mode; broader radio, background and platform
qualification remains open. Exact evidence and earlier failures are in `Audio-Transport-Policy.md`.
Recognizing an extension message does not grant a new source mode to an existing strict stream.

## Ownership and admission

Audio is a separate permission from remote control and general file access. Use the
existing authenticated product connection, exact peer protocol identity, current
key/session incarnation, and a fresh account-device membership decision. Device
names, self-reported account metadata, discovery TXT and an online icon do not grant
audio access. Receiver approval binds one stream, source descriptor, output endpoint
and current session owner. A replacement connection, revoked account/device approval,
permission loss or rekey terminates the old stream and its queues.

The shared wire codec performs structural validation only. It neither authenticates
messages nor authorizes playback. Consumers must validate their exact current owner
before and after asynchronous work and before each native or network effect. Audio
must not overwrite existing transport callbacks or bypass existing bootstrap gates.

For WebRTC, reserve SBWC packet type **7** for this contract. Type 6 remains the separate
BoundSession carrier, excluded from generic application admission. Mac, iOS, Android
and Windows must use explicit accepted-type sets, not a widened integer range. This
reservation does not enable sending until the authenticated peer and local installed
consumer advertise the corresponding versioned role. Existing `audio_transfer` or
`REMOTE_DESKTOP_AUDIO` support does not imply support for this contract.

For the existing MAIN connection (LAN or an actual USB carrier), use the existing
binary `SBE1` envelope: kind **2**, eight-byte timestamp **zero**, followed by exactly
one complete SBAU message. Maximum plaintext envelope size is **12,301 bytes**.
Kind 1 remains remote desktop. The connection's current AES-GCM, padding and length
framing remain unchanged; this is not SBWC type 7. Recognized but malformed audio
must fail explicitly, without being reinterpreted as JSON or remote-desktop data.

The initial native adapters permit one audio channel per exact paired connection,
with eight pending received messages and at most 64 stream IDs per key epoch.
Stream IDs are never reused or evicted within that epoch. Closing audio, or its
receive queue overflowing, produces an observable terminal and retires that stream
without closing MAIN; only late packets for explicitly retired IDs are discarded.
Unknown streams still fail admission. A framed write has a five-second deadline;
timeout/partial-write failure can close that exact unusable transport. No new
connection may be affected by a late completion or timeout from an old owner.

The carrier adapters themselves prove transport ownership and accepted pairing metadata
only. The Mac app now composes the inbound MAIN consumer with account membership,
one-stream receiver permission, message/window enforcement and native output. Capture
advertisement belongs to the exact ready handler installation; removing an old handler
cannot withdraw its replacement. Outgoing Mac MAIN, file receive, WebRTC, iOS and Windows
do not gain an audio receive role merely by sharing this codec.

## Original files and captured PCM

Original files reuse the existing verified file-transfer protocol. An audio file offer
binds an exact transfer UUID, byte length and complete SHA-256. Accepting it permits
only that artifact for this playback session, not arbitrary file transfers or paths.
The receiver must use an owned temporary object, verify the received length/hash and
current transfer owner, then hand that exact object to its decoder. Another path with
the same display name is not a substitute. The file transfer and audio lifetimes must
coordinate cancellation and cleanup. Unsupported containers/codecs are explicit
failures; an offer or transfer receipt does not establish decoder/output support.

The Kotlin, Apple ProtocolCore and Windows native-FLAC metadata inspectors share
bounded source-declaration fixtures. Metadata inspection alone does not enable playback.
The Mac consumer additionally uses pinned libFLAC 1.5.0 and a complete validation pass;
Android and iOS send original FLAC only to an approved peer that advertises
`audio_flac_file_receive_v1` together with `audio_file_receive_v1`. Windows also has
source-level strict FLAC receiver integration; its native DLL, UI, output and device
acceptance remain unverified. Structural/source support alone cannot advertise a role.
Unknown total frames and absent STREAMINFO MD5 remain explicitly unknown. Standard
FLAC channel layouts follow RFC 9639; a case-insensitive channel-mask tag overrides
that default, including explicit zero or partial masks. Output admission must not
discard unassigned channels or silently replace an explicit mask.

For integer FLAC decoding, the common representation is interleaved little-endian
PCM with valid bits high aligned in the smallest 8/16/24/32-bit container; 8-bit uses
offset binary. FLAC declares integer precision, not a PCM byte-container width. This
reversible representation rule does not permit changing rate, precision or channel order.
Metadata inspection alone proves no decoded samples: the decoder must check frame
declarations, complete sample count, exact input end, error callbacks/CRC and available
PCM MD5. Existing authenticated SHA-256 file commitments remain independent and required.

Captured PCM carries the bytes returned by the system capture boundary. Its format
describes that boundary, not the music app's original encoding or effective precision.
The initial implementation performs no sample conversion. Receiver output-ready must
match the offered PCM format; later value-preserving representation adapters require
an explicit negotiated contract and their own evidence. Source file bytes and decoded
PCM bytes are distinct guarantees.

### iOS system-capture availability (2026-10-18)

The device's current ScreenCaptureKit availability is separate from SDK/OS
support and consent for a particular capture. On iOS 27+, the product reads
`SCContentSharingPicker.isAvailable`, which reports whether screen recording is
supported and allowed on the device. Older systems and a currently unavailable
device have distinct presentation states. The source owner rechecks availability
before creating a source or opening an audio channel; the native backend checks
again before presenting the system picker. An availability result never replaces
the picker, account lease, peer identity or playback approval.
[Apple API contract](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker/isavailable)

The playback sheet explains an unavailable system source while leaving original
file playback independently selectable. Controlled regressions cover unavailable
and changed availability before channel opening, preservation of an already owned
source, native CoreMedia sample/timestamp contracts, capture cleanup and encrypted
sender admission. The final test product passed 109 tests with zero failures or
skips on a dedicated iOS 27 simulator. Earlier attempts on the existing simulator
did not reach test execution; those launch diagnostics remain retained. They are
not passing runs or a proven root-cause diagnosis.

The updated iPad app's read-only native probe reported `available` and the declared
`screen-capture` background mode. It presented no picker and started no capture.
Actual system recording, background continuity, USB captured-PCM transmission
and strict hardware output remain separate physical gates. Evidence:
`ios-system-audio-availability-v1`.

## USB original-file return stream (2026-10-18)

The Apple adapter reuses the existing file protocol on a host-initiated USB stream.
The mobile sender advertises `audio_file_usb_return_send_v1` in committed pairing
metadata. A Mac receiver advertises `audio_file_usb_return_receive_v1`, together
with the normal file/FLAC receiver roles, only for a running consumer, an exact
USB device bound to this connection, and a peer that advertises both the sender
role and `classic_approval_v1`. Older senders do not gain a USB file role.

After the existing file offer and receiver account/playback admission, the
receiver registers the exact private-file grant and sends `accept(window=0)`.
The sender creates a one-use listener bound only to `127.0.0.1`, then publishes
opcode **17 usbFileRoute** on that same authenticated audio stream. Its body is
`port(2), reserved(2)=0`; the port is nonzero and all integers use network byte
order. No host address is accepted from the peer. The stream UUID already binds
the route to the offered transfer, and a second route is rejected.

The Mac re-enumerates usbmuxd and opens that port on the exact bound USB UDID;
Network entries are excluded. The iOS route also requires the committed receiver
capability and a loopback MAIN endpoint. Missing capability or USB connectivity
is an error, never an implicit LAN fallback. The native file stream then uses
the existing metadata MAC, authenticated receiver approval, AEAD chunks and
matching file receipt. Metadata remains MAC-authenticated plaintext as in that
protocol; file chunks cannot be sent before approval authentication.

The receiver passes `purpose: .originalAudio(exactTransfer)` to the existing file
manager. A replaced/missing grant, other transfer ID, general resume request or
missing approval protocol is rejected. A USB-bound grant cannot be claimed from
the ordinary network file listener. File bytes and source-format requirements
are unchanged. The file manager retains its existing socket cancellation at the
end of reception; the USB owner observes native cancellation before declaring
resource closure instead of issuing another read on the closed stream. Both
ends retain unresolved cleanup obligations, and closing this file stream never
substitutes for closing MAIN.

Current USB validation comprises 134 focused Mac tests and 66 iOS 27 simulator tests,
including native loopback file/receipt exchanges and close observations. The
Mac USB dial is substituted in those tests. A separate physical iPad-to-Mac run
used the real account provider and a Q-Periapt USB session: a 288,068-byte,
48 kHz/24-bit stereo WAVE returned a matching authenticated file receipt, followed
by `unsupportedOutput` at the strict output preparation gate. Source/file cleanup
was confirmed; the MAIN session remained authenticated. The native test entry
does not establish file-picker UI acceptance. Full playback, physical unplug
recovery and strict hardware output remain separate gates. Android and Windows
USB adapters are not implemented by this Apple extension. Evidence:
`apple-usb-original-file-v1`, `ios-usb-original-file-product-v1`.

## Binary wire

All integers below are unsigned, big-endian, except PCM sample bytes, which are
little-endian interleaved samples. UUIDs use their 16 RFC/network-order bytes (not the
default mixed-endian .NET Guid byte array). All-zero stream/transfer UUIDs are invalid.
Maximum complete audio message: **12,288 bytes**, before SBWC/padding/framing. A carrier
may impose a smaller negotiated limit. No untrusted allocation may exceed that bound.

Common header (28 bytes):

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `SBAU` |
| 4 | 1 | Version = 1 |
| 5 | 1 | Opcode from table below |
| 6 | 2 | Reserved = 0 |
| 8 | 16 | Stream UUID, new for every source/format generation |
| 24 | 4 | Exact body length; trailing or missing bytes are invalid |

| Opcode | Body | Meaning |
| --- | --- | --- |
| 1 fileOffer | transferUUID(16), length(8), SHA256(32) | Original file, 1..16 GiB |
| 2 captureOffer | PCM format(16) | System capture, original source format unknown |
| 3 accept | receiveWindowBytes(4) | Receiver's local grant: file=0, PCM=1..1 MiB, frame aligned |
| 4 pcmData | byteOffset(8), nonempty PCM bytes | Exact contiguous offered-format frames |
| 5 credit | retiredBytes(8) | Absolute bytes removed from receiver's PCM input queue |
| 6 end | totalBytes(8), SHA256(32) | PCM sender's final content commitment; no further data |
| 7 contentVerified | totalBytes(8), SHA256(32) | Receiver actually verified this content |
| 8 outputReady | PCM format(16) | Selected native endpoint opened for this format |
| 9 playbackComplete | sourceFrames(8), trailingPaddingFrames(4) | Receiver confirmed final device progress |
| 10 stop | reason(2), reserved(2)=0 | Terminal cancellation/failure, never completion |

### Explicit Opus Bluetooth extension

This is a lossy compatible mode for an actual authenticated Bluetooth carrier, gated by
`audio_opus_bluetooth_receive_v1`. USB and Wi-Fi original-format playback must not silently
select it. Capability publication requires an installed compatible receiver, verified account
membership, a current authenticated session/physical route and an output implementation;
parsing support, OS pairing, discovery or a codec library is insufficient. The Apple Bluetooth
receiver is currently enabled only by the explicit local qualification gate described below.

Opcodes 1–10 and their original-file/PCM encodings remain unchanged. Older peers need not
understand the extension; a sender must verify the explicit role before offering it. The
common header, stream identity, bounded framing, encryption, replay/owner checks and Stop
semantics remain mandatory. No Opus bytes may appear in pcmData or a file grant.

| Opcode | Body | Meaning |
| --- | --- | --- |
| 11 opusOffer | codec(1)=1, sourceKind(1), channels(1), reserved(1)=0, sampleRate(4)=48000, packetFrames(2)=960, reserved(2)=0, bitrate(4) | Explicit compatible profile; sourceKind=1 selected file, 2 system capture; channels=1/2; CBR bitrate=128000/192000/256000 |
| 12 opusConfiguration | preSkipFrames(2), reserved(2)=0 | Actual per-instance initial decoder delay, 0..3840 frames at 48 kHz; exactly once, before data |
| 13 opusData | sequence(8), exactly one raw Opus packet | Sequence begins at zero, contiguous; packet size exactly bitrate/400 (320/480/640); decoded duration exactly960 frames |
| 14 opusEnd | sourceFrames(8), packetCount(8), totalEncodedBytes(8), SHA256(32) | Finite input completion with encoded-content commitment and exact source count |
| 15 opusOutputReady | empty | Compatible renderer prepared for the negotiated decoded input; not a bit-perfect hardware-format claim |
| 18 bufferedOpusFileOffer | Same 16-byte profile layout as opcode 11, with sourceKind=1 only | Negotiated finite-file buffering: 64 packet slots and 46,080-frame startup prefill; requires `audio_opus_buffered_file_receive_v1` in addition to both Bluetooth capabilities |

Opcode 18 does not change codec parameters or existing opcode bytes. The sender chooses it only
when the current authenticated receiver advertises all three capabilities. Otherwise it may
offer the original opcode 11 directly; it must not retry a rejected opcode 18 as an implicit
policy downgrade. The canonical offer bytes are included in the existing child-key derivation
and confirmation context, binding the selected buffer policy to the exact child. A source-kind
value other than selected-file is invalid for opcode 18. System capture retains opcode 11.
The receiver must implement the larger bounded decoder/native queue before advertising this
capability; merely recognizing opcode 18 is insufficient. Currently only the Apple file sender
and receiver implement this mode; Android and Windows retain their existing opcode 11 contract
and do not advertise this new capability. This does not establish their native playback readiness.

The offer is available without reading the source. Following current-owner/account checks,
the receiver approves this exact source kind/profile and selected endpoint, then sends Accept
and opusOutputReady. The sender begins capture/PCM encoding only after both have arrived,
publishes the actual instance's pre-skip, then sends packets. Bounded declaration inspection
of an explicitly selected file may precede the offer under that file's existing user grant
and account preparation checks; it does not permit transmitting audio. This avoids capturing
audio merely to discover CSD before approval. Missing configuration, duplicate configuration,
source/profile changes, original OutputReady, PcmData, or ordinary End in this mode are errors.
Seek preroll must never replace initial pre-skip. A changed bitrate/profile currently requires
a new stream; dynamic rate adaptation is not defined by this initial extension.

The decoded input is interleaved 48 kHz signed PCM16 with mapping-family-zero mono/stereo order.
It describes the compatible codec boundary, not the original file's rate/precision. Preparing
that boundary from another format requires a separately implemented and validated compatible
source adapter; the encoder itself must not silently resample or truncate input. The sender's
source-kind field is not capture permission or original-source attestation.

Accept/Credit count encoded packet payload bytes in this mode, excluding framing and codec
configuration. Opcode 11 retains sixteen packet slots, hence a window of 16 * bitrate/400 bytes.
Opcode 18 uses exactly 64 * bitrate/400 bytes. The source requires the exact offered policy's
Accept window and retains that window for the stream lifetime. A sender cannot send another
packet without that credit; End and Stop
remain bounded control messages. Packet sequence is less than floor(Int64.max/960). End has
positive source/count/byte fields, sourceFrames <= Int64.max-3840, count <= floor(Int64.max/960),
and a byte total of count times one supported packet size. Consumers additionally require the
negotiated size and exactly their received counters. These scalar checks do not replace decoding.

SHA256 commits to the concatenation of raw encoded packet bytes in sequence order. Metadata,
stream ID and counters are bound by the existing authenticated message/session envelope;
fixed packet size makes this concatenation unambiguous. ContentVerified echoes that encoded
byte count and digest only after the full encoded content and end counts validate. It is not
proof of equality to original PCM/file bytes and is separate from actual playback completion.

The product decoder discards initial delay, holds at most the last decoded packet, and releases
its valid tail only when sourceFrames is known. After trimming pre-skip, exactly sourceFrames
must remain and discarded tail must be in 0..<960 frames. Failure cannot synthesize missing frames
or invoke concealment to report success. Native enqueue failures terminate the flow before
committing the affected packet's hash/credit accounting.

Credit advances only when complete decoded packet contributions leave the current native queue.
Wholly skipped delay packets may retire without inventing source progress. The last packet's
discarded codec padding does not earn premature credit: its remaining encoded extent retires
only after verified content and actual native drain with the exact final source count. This
final acknowledgement is also withheld at exact packet boundaries with zero codec padding. The
receive-flow component accepts explicit native progress observations; tests supplying simulated
progress are not physical-output proof. Codec tail padding is separate from device queue padding.
PlaybackComplete's sourceFrames uses this 48 kHz decoded-source timebase; its trailingPaddingFrames
does not include discarded Opus delay/tail. For the compatible AVAudioEngine renderer below,
zero means no extra PCM frames were submitted by this consumer. It is not a measurement of
framework resampling tails or device silence. Strict original-format playback retains its
existing measured native-padding contract; the unadvertised compatible extension does not
claim a device-level padding count or bit-perfect output.

The current bounded flow has no authority to open output, accept a peer or advertise a role.
Authentication, one-stream permission, revocation, output scheduling, transport backpressure,
underrun handling, source/output clock drift, background operation and real Bluetooth stability remain required integration
and device gates. The structural extension alone must not enable a product playback button.

### Compatible Mac output and decoder consumer (2026-10-18)

The `AudioOpusPlayback` actor connects the bounded receive flow to `CoreAudioOpusOutput`. The
caller must first establish the exact Bluetooth child, finite account lease and one-stream
permission, then supply their current-effect check. This serial consumer prepares output,
returns Accept/OpusOutputReady, submits decoded chunks, generates packet-aligned credit from
native playback progress, verifies End and generates completion only after native drain and
cleanup. The caller still owns transport reads, bounded control writes, Stop/error reporting
and successful delivery. Neither component registers a MAIN handler or advertises a role.

The compatible renderer explicitly uses 48 kHz signed PCM16 mono/stereo input. Integer samples
are represented exactly as normalized Float32 for AVAudioEngine; the system mixer may convert
to the selected device format. It selects and rechecks the exact endpoint, does not request a
hog lease or write global device rate/volume properties, and is not a fallback from strict preparation.
For opcode 11 its queue is limited to 16 buffers and 15,360 source frames, with 9,600-frame
startup prefill. Opcode 18 uses at most 64 buffers and 61,440 source frames, with 46,080-frame
(960 ms) startup prefill. The output policy must match the authenticated offer before preparing
the endpoint. Decoder delay and final-packet holdback fit inside this bounded window; neither
receiving a packet nor scheduling a native buffer is evidence of actual playback.
A verified shorter finite input can start below that prefill. Missing input, engine/endpoint
changes, authorization loss and non-monotonic established timelines fail the stream.

AVAudioPlayerNode completion callbacks also fire when stopped. The owner therefore retires
its callback ledger before native stop; stale callbacks cannot earn credit or completion.
An accepted buffer commits only after scheduling returns. Out-of-order callbacks cannot skip
a pending buffer, and duplicate/wrong-kind callbacks fail. Native startup can initially report
negative source times; those remain a bounded pre-start wait, not synthesized zero progress.
Once a nonnegative timeline has been observed it cannot regress. Completion requires the exact
End count, contiguous played-back callbacks, a current timeline past the source end and released
native resources. Failed cleanup retains the same owner for explicit retry.

The current Mac executed the canonical product decoder/consumer/output with a quiet 24,000-frame
synthetic source: 26 CBR Opus packets, verified encoded content, exact native source-frame
completion and bounded queue. A separate synthetic effect-authorization revocation run stopped and released the
output without a completion report. The initial timeline failure and the native
stop-callback counterexample are retained. These are in-process native checks, not phone radio,
long-duration/background, listening-quality, account admission or installed-app acceptance.

Original-file implementation boundary: the Android classic sender currently admits at most
2 GiB, independently of SBAU's 16 GiB wire ceiling. Its prepared audio artifact fixes the
transfer UUID, length and SHA before an offer and is consumed once by the existing authenticated
classic sender. The Mac carrier can validate classic key material against the exact current
audio owner; use the original authenticated transfer-ID string for KDF input, including case.
UUID equality alone must not substitute for this key/owner check. Consumer admission must also
match the offer's length/digest, current account lease and one-stream playback permission.

The shared Apple WAVE inspector returns unmodified PCM format declarations and a byte range
from a caller-owned verified reader. It performs no decoding or output admission. Its RIFF
limit, maximum 4096 chunks and 40-byte read bound are separate from transport policy. The inbound
I/O actor's prepared-reader handoff requires a verified, uncommitted staging handle and checks
the recorded file identity and complete digest on reopen. This is not continuous retention of
the receive descriptor across `closeAndDigest`. The returned reader owns a new held descriptor;
the consumer owns closing it, staging cleanup and authorization checks before read/output.
The Mac app's shared playback session now registers an original-file grant only after its
account lease and local playback approval succeed. After validating the metadata MAC, the classic
listener can claim that exact grant using its current key material. A matching invalid grant fails
instead of falling through to ordinary file approval. The receiver reuses chunk crypto, scan policy
and durable commit, stores this artifact in private cache rather than Downloads, and retains the
IO handle plus prepared reader for playback and cleanup. Only an installed verified-file consumer
may advertise the file receive role. The Mac consumer accepts PCM/IEEE RIFF/WAVE and
finite native FLAC; the stronger FLAC capability requires that concrete consumer.

FLAC source declarations and complete decoding are bound to the same held, block-commitment
reader. The validation factory derives metadata itself, including explicit channel-mask tags.
It rejects unknown sample counts and durations above four hours, and checks frame continuity,
CRC/error callbacks, exact encoded EOF/sample count and available MD5 before opening output.
Missing MD5 remains explicitly unavailable, never falsely verified. The original authenticated
file SHA-256 remains mandatory. Validation, including metadata reads, has a 180-second absolute
monotonic deadline; output preparation retains its separate 10-second deadline. Mobile senders
use a bounded 200-second FLAC output-preparation wait, while WAVE retains its 15-second wait.

Playback makes a new sequential decoder over the same committed reader. The Swift adapter
holds at most one complete decoded frame (up to 2,097,120 bytes) and supplies the existing pump
with at most 64 KiB per frame-aligned read. It does not cache a whole decoded file, resample,
normalize gain, or permit native error recovery/padded missing frames. Cancellation and account
revocation apply even to already decoded pending samples; failed owners cannot resume. Decoder
cleanup and the outer reader/output cleanup remain distinct. A second exact decoder completion
is required before native input is sealed; only native output drain and completed cleanup permit
PlaybackComplete. These checks do not establish independent physical/DAC sample acceptance.

For file streams, Accept has window zero. The Android sender independently inspects its held
artifact through commitment-verified absolute reads before sending FileOffer; it cannot guess
the file's format from a capture profile. Exact OutputReady can be observed before the classic
receipt because the two sockets are independent. Successful sender completion nevertheless
requires the authenticated exact-file receipt, matching output format and matching source-frame
PlaybackComplete. PCM, credit, end and ContentVerified are invalid controls in this file mode.
Completion deadlines use verified source duration plus bounded grace, not a short capture timeout.

Android source preparation accepts an explicitly unknown declared length. It copies to EOF into
the same owned private snapshot with the existing 2 GiB classic limit, hashes source bytes during
copy, then builds chunk commitments through its held snapshot descriptor. The two hashes must
match before publication; a same-size rewrite between copy and inspection must not become the
selected source. Known declared lengths still require exact length. No URI reopen, typed-provider
conversion, full-file memory buffer or second application spool is implied by this API.
The caller owns the preparation deadline and cancellation of SAF opening. During a blocking read,
the application must monitor authorization expiry/revocation and cancel its operation. Cancellation
closes the source and waits for its worker; a provider ignoring close can delay completion.

The Android document adapter uses one unstable ContentProviderClient for cancellable query and
direct openFile("r"). Its source boundary is the bytes returned by that provider method, not an
attestation about provider internals or upstream music. Do not substitute ContentResolver's read
helper: the inspected API 36 implementation and an actual SDK 37 synthetic-provider probe dispatch
that helper through typed asset conversion. The adapter rejects virtual/non-document input,
reconciles optional metadata/stat lengths, and delegates the one private snapshot to existing core.
The app uses only read operations and does not persist the grant; ACTION_OPEN_DOCUMENT can itself
grant broader document permissions, so this is not a claim that the OS grants read-only access.

Preparation has one admission slot and a 120-second caller deadline. Cancellation independently
signals the provider and closes the owned stream/descriptor, then waits for both actions and the
worker before releasing the provider client. A descriptor returned after cancellation still has
an owner. Unconfirmed cursor, stream, descriptor or client cleanup retains that owner and the slot;
later preparation fails explicitly and requires actual process termination, not activity recreation.
Cleanup failure remains visible even when the primary failure is cancellation. An uncooperative
provider can exceed the deadline while cleanup is pending; the UI must not report that as released.

File mode forwards the selected URI with a transient read grant to the same non-exported service,
using the connectedDevice foreground type; only capture mode requests record/projection consent
and uses mediaProjection. Picker/permission results bind an exact operation and expected phase.
Cancellation remains busy until service cleanup settles. The preparation lease watcher is joined
before the sender assumes resource ownership; the sender then owns ongoing authorization checks.
The source format displayed by the app comes from held, commitment-verified WAVE or FLAC inspection.

The Mac file pump reads at most 64 KiB of whole frames, uses native queue/progress observations,
preserves sample bytes and rejects non-finite float samples before enqueuing the affected block.
Earlier queued samples can already have played; a later invalid block terminates the stream.
Neither a timer nor submitted-frame count alone proves completion. Native completion already
requires output release/restoration; the shared session also settles the private file before
sending PlaybackComplete. A file cleanup failure sends Stop, retains its exact owner, and cannot
become success on cleanup retry. Descriptor retention continues through identity-bound unlink.

If a cancelled receive producer has not ended after a five-second cleanup wait, cleanup returns
pending and retains its registration/resources. It does not abandon the producer or unlink files
still in use. An explicit coalesced retry may clean them once actual producer termination is known.
This bounds that wait; it does not forcibly interrupt arbitrary underlying synchronous OS calls.

PCM format (16 bytes): rateHz(4), channels(2), encoding(1), declaredValidBits(1),
layoutPresent(1), reserved(3)=0, waveChannelMask(4). Encoding values are 1=unsigned8,
2=signed16, 3=signed24 packed, 4=signed32, 5=signed64, 6=float32, 7=float64.
Integer valid bits are 1..container width; float valid bits must equal container
width. Rate/channels are nonzero, bytes per frame fit UInt16, bytes per second fit
UInt32. Valid bits refer to declared representation precision, not an inferred
upstream source. WAVE integer bits narrower than their container are left-aligned.
`layoutPresent=0` requires mask=0 and means unknown; `layoutPresent=1, mask=0` means
explicit DIRECTOUT. Android masks must be translated by meaning, not copied as WAVE
mask values. An unknown layout cannot be silently replaced at output.

Offsets/counts fit signed 64-bit on every platform (0..2^63-1); sums must be checked.
File length is additionally bounded above. Exact 32-byte hashes are mandatory, not
optional placeholders. Control body sizes are exact. Unknown versions, opcodes,
encodings, reasons, reserved bits and malformed sizes fail explicitly.

Stop reasons: 1=userStopped, 2=permissionRevoked, 3=sourceFailed,
4=unsupportedOutput, 5=queueOverflow, 6=outputLost, 7=protocolViolation,
8=accountRevoked, 9=sessionReplaced, 10=timedOut, 11=contentMismatch,
12=unsupportedSource, 13=receiverDeclined. No arbitrary peer text is displayed as a
trusted system message. The reason code is a peer report, not independent proof of
DRM behavior or physical hardware state.

## Stream state and completion obligations

One pending offer per peer owner and one active output per selected endpoint. Offers
expire after a bounded local deadline; retries or duplicate messages do not extend it.
Accept must refer to the exact pending offer after current local permission checks.
Data/credit for unknown or unaccepted streams are rejected. Data for an explicitly
retired stream can only be discarded by its same-epoch carrier tombstone; it can
never reach a replacement stream or output. Reconfiguration
requires a new stream UUID and fresh output admission; old queued bytes cannot leak
into its replacement. Format metadata is immutable for a stream.

For PCM, the accepted window remains fixed. Sender starts at offset zero and must
keep `sentBytes <= retiredBytes + windowBytes`. Retired bytes must be monotonic, no
greater than sent bytes and frame aligned. Receiver admits contiguous data only,
validates complete frames and bounded available capacity, and grants credit only
after actually retiring those bytes. Credit is neither a playback receipt nor an
audio clock. File mode uses the file protocol's own bounded flow control; PCM data
and credit/end messages on a file stream are invalid. File mode uses the exact
authenticated file-transfer completion instead of a second audio end handshake.
A queue overflow or lost capture samples
terminates strict continuity instead of silently dropping, duplicating or resampling.

`outputReady` is separate from `accept`, `contentVerified` and `playbackComplete`.
File content verification must come from the existing verified transfer's exact
artifact before playback; PCM content is checked incrementally and at end. The
complete byte count/hash must agree with the accepted descriptor/received sequence.
PCM EOF without authenticated audio end, or file EOF without the bound verified
file-transfer completion, is not completion. Transport acknowledgement and
WASAPI submitted-frame counts do not prove the last frames played. Completion needs
bounded native drain/progress evidence and separately counts any necessary trailing
padding (not music frames). Stop, timeouts and unverifiable progress remain distinct.

An exact native format is not DAC bit-perfect proof. Product status separates original
file verification, capture-boundary PCM preservation, actual output configuration and
independent digital loopback. Live clocks cannot promise indefinite fixed latency,
unchanged samples and no interruptions using a finite buffer.

The captured-PCM session adapters now enforce this window, offset, digest and
completion sequence. Sender admission has one fixed deadline (default and maximum
120 seconds); repeated messages do not extend it. Capture opens only after accept
and exact outputReady. Graceful finish sends the final complete-frame tail and end;
cancellation never becomes a successful end. The Mac receiver handles peer stop
while account, local approval or native preparation is pending and awaits owned
resource cleanup before returning. The Mac application starts its approval presenter before
installing the inbound MAIN receiver. The Android device action uses an existing approved
MAIN owner, then obtains system consent and starts a mediaProjection foreground service.

Both native carriers recheck the effect authorization after obtaining the write
gate, before admitting a frame for submission. This rejects authorization revoked
while a write was queued. Passing that check admits a bounded in-flight operation;
it is not an atomic transaction with account/permission revocation and cannot
retract bytes already admitted or submitted. Effect predicates must not reenter
the carrier's owner lock.

The CoreAudio finite-output adapter separately tracks source frames and trailing
silence. It freezes EOF, records the last source-frame end in the callback output
sample-time domain, and requires running-device progress to reach that point plus
device and stream latency. Timestamp validity, continuity and clock properties must
remain verifiable. Empty input has a separate completion status. Successful stop,
final source counters and owned-property restoration are required before publishing
completion. The bounded watchdog only detects failure; elapsed wall time cannot
prove playback. This is HAL-reported progress, not independent digital-loopback or
physical-DAC evidence. See Apple's [IOProc contract](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)
and [device clock](https://developer.apple.com/documentation/coreaudio/audiodevicegetcurrenttime(_:_:)).

The Mac consumer retains an exact output owner when cleanup remains pending and rejects
new output admission until it is released. An explicit retry performs one serialized
close attempt without restarting playback or changing the failed stream's result.
Released resources, historical close diagnostics, transport Stop delivery failure and
deliberately preserved third-party settings are separate outcomes. App termination waits
for cleanup; unresolved resources are shown to the user before an explicit exit decision.
Preserving a third-party property value does not mean the original format was restored.

## Implementation and verification gates

The canonical shared Apple codec lives in `SkyBridgeProtocolCore`; Kotlin and C# use
the same fixed vectors. Codecs must reject truncation at every boundary, extra bytes,
unknown values, overflow and oversize input. Codec tests are not session authorization
or native playback tests. Native consumers, exact-owner cancellation, account/receiver
approval, file binding, bounded queues and output readiness must be connected before
advertising either receiver capability (`audio_file_receive_v1`,
`audio_capture_receive_v1`). Missing/old capabilities mean unsupported, not an invitation
to send a new packet to probe a peer.

Each fixed vector is an independent structural message, not a runnable conversation
or a verified media artifact. Digest fields in these vectors are opaque metadata;
actual source bytes, transfer commitments and playback evidence are tested separately.

Mac consumer is created alongside existing consumers in the established inbound
control loop; iOS sends through its current owner and existing secure framing. Windows
consumer joins the established-runtime consumer list; Android shares the existing
current secure owner. Each transport path and each mobile-to-desktop pair retains
its own device acceptance evidence.

## Bluetooth attachment preparation extension (2026-10-17)

This optional MAIN preparation lane requires both `audio_opus_bluetooth_receive_v1`
and `audio_bluetooth_attachment_v1` from the exact approved receiver pairing. The Apple
receiver publishes these only when its explicit local qualification consumer is installed.
Opcode 18 additionally requires `audio_opus_buffered_file_receive_v1`. Defining this extension does not
qualify native Bluetooth attachment, account admission or playback.

Opcode 16 (`bluetoothRoute`) has a 36-byte body: big-endian LE PSM u16 (1...255),
reserved-zero u16, service UUID (16 network-order bytes), publication UUID (16 bytes).
Both UUIDs and the enclosing stream UUID are nonzero. The route identifies a CoC
publication, not an account identity. A source sends exactly one Opus offer (opcode 11 or 18);
a sink replies with exactly one route. Stop remains available. Media, credit, output
readiness and strict file/PCM messages cannot travel on this preparation lane.

The existing current Finished/pairing owner records the exact messages. An outgoing
message is committed only after actual native write completion and another owner check.
A single attachment can be taken after both messages commit; replacement pairing,
rekey, channel closure or parent retirement invalidates it. Preparation lasts at most
30 seconds from issuance. It does not detach authority from MAIN or extend an account lease.

The confirmation building block uses HKDF-SHA256 and HMAC-SHA256, reusing platform
crypto primitives. This is an application-specific binding, not a TLS exporter.
[HKDF](https://www.rfc-editor.org/rfc/rfc5869) provides the extract/expand primitive;
that reference is not a proof of this application protocol.

`context = SHA256(UTF8("SkyBridge-Audio-Bluetooth-Binding-v1|") || suiteBE16 ||
parentTranscriptHash32 || exactOfferWire44 || exactRouteWire64)`.
The IKM is the source-to-sink MAIN key followed by the sink-to-source MAIN key (32 bytes
each). HKDF salt is the parent transcript hash; info is
`UTF8("SkyBridge-Audio-Bluetooth-Attachment-v1|") || context`, output length 32.
Confirmation is HMAC over `UTF8("SkyBridge-Audio-Bluetooth-Confirm-v1|") || context ||
roleU8 || sourceNonce32 || sinkNonce32`, with source role 1 and sink role 2.
Nonces must have exact length and differ; native owners must generate fresh random
nonces for each single-use CoC attempt. Independent Python vectors cover wire, KDF,
direction and proof; live carrier tests cover current-owner issuance.

The native challenge exchange and ordered authenticated records are implemented by
`BluetoothAudioChannel` in the Apple transport module and Android core. Native service
publication/discovery adapters are implemented as described below. The existing Mac receive
session can install the concrete adapter and decoder/output coordinator as described below;
the Android product sender remains to be connected. Default startup advertises neither
Bluetooth capability. Recognizing or constructing the components does not enable playback.
A future independently established Bluetooth media lifetime must distinguish ordinary
Wi-Fi loss from explicit disconnect/revocation and preserve finite account permission;
this preparation handle currently fails closed with its exact parent. Windows does
not advertise this CoC extension; its existing decoder rejects unsupported opcodes.

### CoC confirmation and encrypted records

The outer framing is the existing big-endian four-byte length. Handshake frames have a
24-byte header: ASCII `SBAB`, version u8=1, kind u8, reserved u16=0, stream UUID16.
The only permitted bodies are:

| Kind | Body | Total frame body bytes |
|---|---|---|
| 1 Hello | source nonce32, Hello MAC32 | 88 |
| 2 Challenge | source nonce32, sink nonce32, sink confirmation MAC32 | 120 |
| 3 Finish | source nonce32, sink nonce32, source confirmation MAC32 | 120 |
| 4 Ready | source nonce32, sink nonce32, Ready MAC32 | 120 |

Using the root key derived above, Hello is HMAC-SHA256 of
`UTF8("SkyBridge-Audio-Bluetooth-Hello-v1|") || context || sourceNonce32`.
Ready is HMAC-SHA256 of `UTF8("SkyBridge-Audio-Bluetooth-Ready-v1|") || context ||
sourceNonce32 || sinkNonce32`. Challenge and Finish use the existing role-specific
confirmation formula. Distinct Ready authentication prevents reuse of the Challenge
MAC as final confirmation. Headers, lengths, version, kind, reserved bits, UUID and
nonce pair must match exactly; there is no trial decoding or alternate protocol.

The sink verifies Hello before claiming its pending attachment. An unauthenticated or
competing candidate closes only its own native socket, not the pending or established
owner. Each attachment can be claimed once. Every outbound transition is committed
only after native write completion; source media keys require a verified Ready, and
sink media keys require completed Ready transmission. All steps share the original
30-second preparation deadline. The established cipher no longer uses that deadline,
but still rechecks its exact parent and the caller's effect authorization. The latter
must check the finite account grant and local playback permission; this API does not
create either grant.

`sessionContext = SHA256(UTF8("SkyBridge-Audio-Bluetooth-Session-v1|") || context ||
sourceNonce32 || sinkNonce32)`. Direction keys use HKDF-SHA256 with the root key as
IKM, `sessionContext` as salt, and `UTF8("SkyBridge-Audio-Bluetooth-Traffic-v1|") ||
senderRoleU8` as info, producing 32 bytes. Source and sink use independent keys.

An encrypted record is `counterBE64 || ciphertext || GCMtag16`. AES-256-GCM uses the
implicit 12-byte nonce `zero4 || counterBE64` and authenticates
`UTF8("SkyBridge-Audio-Bluetooth-Record-v1|") || sessionContext || senderRoleU8 ||
counterBE64`. Plaintext is exactly one existing SBAU message. Each direction starts
at counter 1, accepts only the next contiguous value, and stops after 2^24 records;
there is no wrap, retry under a consumed nonce, or silent rekey. New attempts require
fresh random nonce pairs. The platform AEAD primitive does not itself provide replay
or access control; those are separate state checks, as distinguished in
[RFC 5116](https://www.rfc-editor.org/rfc/rfc5116.html).

The record limit is 700 bytes, or 704 including outer framing. A 192 kbps packet is
480 encoded bytes and occupies 544 bytes including all application framing and AEAD.
The source may send configuration, negotiated-size Opus packets, matching Opus end,
or Stop. The sink may send packet-aligned window/credits/integrity acknowledgments,
Opus output readiness, positive-frame playback completion, or Stop. Offers, routes,
strict file and PCM bodies cannot enter the established child. These shape/role
checks do not replace stream-state, credit, digest, codec, output or lease checks.

Native owners are allocated before asynchronous connection/authentication. Admitted
cancellation retires only that child. Effect checks run before native writes (including
Android buffered flush and Apple partial writes), after receives and before delivery;
already submitted bytes cannot be retracted. Android queued mutex cancellation does
not cancel the admitted owner; Apple rejects a second concurrent reader/writer.
Cleanup retains primary and native-close failures. `closeAndAwait` checks actual
admitted-worker completion and native worker exit with bounded observation; an
unconfirmed exit retains the same owner for another check and is never reported as
successful cleanup.

Independent public vectors cover all four handshake frames and both record directions.
Native Foundation pairs and Android loopback socket substitutes cover duplex framing,
revocation and cleanup. They are not Bluetooth radio, real music, background execution,
account enrollment or physical-output evidence. Encrypted record overhead must be
included in the next real-radio qualification.

### Native publication and authenticated-route discovery (2026-10-18)

The Apple `BluetoothAudioListener` owns one encrypted dynamic PSM publication, a fresh
service/publication UUID pair, bounded native candidates and at most one authenticated
media child. Its Core Bluetooth driver runs on the main callback queue. The route is
returned only after successful PSM publication, service addition and advertising-start
callbacks, including an observed `isAdvertising == true`. Publication has a bounded
20-second default deadline (maximum 30 seconds). After publication, acceptance lasts
at most 30 seconds and never extends the attachment's original preparation deadline.

Admission checks the exact PSM and capacity before starting a native stream worker.
There are at most four candidate attempts; each initial Hello read is bounded by
three seconds and the remaining attachment lifetime. Invalid Hello candidates close
their own child without consuming the pending attachment. The matching stream, sink
role and full authenticated route are required. A successful child stops advertising
and removes services; the PSM remains owned until the child closes. Publication and
acceptance also require the caller's current-authorization check.

The listener retains resources before suspension and fences late publish, service and
advertising callbacks during cancellation. Cleanup observers share one task, wait for
native stream completion, unpublish callbacks and stopped advertising, and report
unconfirmed cleanup explicitly. A failed unpublish may be reissued only on an explicit
later cleanup observation of the same retained owner; a pending callback is not
silently treated as success or replaced by a fresh publication.

Android `BluetoothAudioConnector` scans for the service UUID supplied through MAIN,
checks that UUID and connectability again at the callback boundary, unregisters its
scanner and connects a secure CoC using the authenticated route's PSM. Discovery is
bounded by 15 seconds and the remaining original preparation lifetime. Native setup
and cleanup are serialized without holding the callback state lock across platform
calls; the child belongs to the connector before asynchronous authentication. Failed
scan unregistration retains the callback for an explicit cleanup retry. A successful
`stopScan` return proves API unregistration, not a controller-wide stop receipt.

The Android adapter does not use a GATT connection or request connection priority.
The Apple service still exposes the encrypted-read, little-endian UInt16 PSM
characteristic, while the MAIN route remains big endian. System defaults on this
direct path have not been qualified for audio. Earlier passing radio experiments used
a GATT HIGH-priority request plus a settling interval, and default-priority experiments
included late-frame counterexamples. Their results do not qualify this new path.

Three current-Mac native publication/unpublication rounds passed through the real
public listener initializer. Foundation/loopback tests cover candidate and cancellation
semantics; iOS device and simulator shared modules compile under strict Swift 6.
These checks do not establish over-air discovery, authenticated phone attachment,
codec/output integration, continuous playback or background stability.

### Mac receive-session integration (2026-10-18)

`AudioPlaybackReceiveSession` admits an Opus offer only when explicit Bluetooth dependencies
are installed. It acquires the finite account lease, selects the endpoint and obtains one-stream
approval before publishing any service. `AudioPlaybackSource.opus` binds the source kind and
complete codec profile; strict-file or captured-PCM permission cannot authorize it. The approval
panel identifies lossy Bluetooth transport, bitrate and system mixing. Its 48 kHz PCM16 decoded
input description is not a claim about the original file's precision or the hardware format.

The session owns its link before suspension. After native publication, the route must actually
be written on the exact MAIN before its single-use attachment is taken. Only after the child is
authenticated may the compatible output be created and prepared. Accept and OpusOutputReady
travel on that child; media reads begin only after the OutputReady write succeeds. MAIN retains
Stop and parent-lifetime control. This implementation does not preserve Bluetooth playback when
the exact parent is lost, and does not implement Bluetooth-only bootstrap.

The playback actor keeps synchronous native preparation away from the receive-session actor so
that cancellation can revoke permission while preparation is in progress. The session serializes
each awaited decoder/poll operation with publication of its returned control batch; actor
reentrancy cannot move completion ahead of content verification. The existing four-control bound
and cumulative-credit coalescing apply independently of the selected control lane. A receiver
success requires successful completion delivery and confirmed local cleanup. Completion delivered
to the peer proves the native drain checked by the consumer; a later transport-cleanup failure
can still leave the receiver in recovery. A failed write is never treated as successful delivery.

Shutdown cancels and joins setup, media reads and control writes, revokes playback permission,
then closes the exact output, attachment and listener. Failed cleanup retains the owner and
blocks replacement playback through the existing service recovery gate. Explicit cleanup retry
does not restart playback or turn a failed stream into success. For compatible playback only,
the local receipt's format describes decoded PCM and its digest commits to encoded packet bytes.

The service's installation binds both capability flags to the same concrete consumer. Its default
live configuration remains disabled pending the mobile sender and direct-CoC physical gates.
Eight focused session tests use the real membership/approval, MAIN binding, wire messages and
decoder against an Android native-encoder fixture; publication/CoC and output-driver boundaries
are explicit substitutes. They cover decline, cancellation during setup/native preparation,
readiness-write ordering, account revocation, completion-write failure and retained cleanup.
These tests and the rendered approval panel do not establish radio or physical playback acceptance.

### Account routes and ordinary Android entry (2026-10-25)

Later product work does not turn the bounded transport checks above into universal playback
acceptance. The user's ordinary QR connection succeeded but lost its LAN session shortly after
backgrounding; application PCM also reached the receiver and was rejected by strict output
preflight. Ordinary connection-to-background-music acceptance is reopened and remains incomplete.

The account endpoint now returns short-lived LAN control routes only for the exact active
protocol signer. Presence omission/null withdraws the route. The verified live signaling build
is `20261025131124-c418fe46be`; the initial readiness failure and automatic rollback are retained
alongside the later successful promotion. Readiness waiting is bounded and checks the expected
build fingerprint. No database migration or relaxation of account authentication was used.

iOS account rows use the validated route through the existing connection owner, binding account
generation and signer across every suspension. Server-relative route lifetime is anchored to
the start of the HTTP request with a process-local continuous clock, capped at 90 seconds.
Waiting, backoff and device sleep consume the same lifetime. Device removal preserves the
remaining records' original deadlines. Shared model/refresh checks passed 38 tests; the native
iOS simulator route/account selection checks passed 37 tests. Physical iPad account-route
connection and audio have not been qualified by this iteration.

An authenticated inbound Mac control carrier no longer requires a separate file-transfer port
before its connected state is published. An absent file listener remains absent. Its presence
lease moves from the temporary endpoint identifier to the validated stable device ID, retires
the endpoint entry, and retains exact ownership during heartbeats. A stale owner cannot take
another socket's identity or remove its connection. Only a validated identity creates a
persistent device row. The focused Mac presence, route, strict preflight and inbound audio
carrier suites passed 109 tests with no compiler warnings. Their source manifest is frozen in
`artifacts/ios-account-route-20261025/mac-presence-02/`; the linked product was separately packaged
and signed for local qualification, not release publication.

Android's authenticated LAN owner now acquires the existing connected-device foreground service
before publishing usable state. Unauthenticated sockets do not acquire it. A physical 90-second
Home/background observation retained the same TCP connection, application process and foreground
service across 19 samples, with increasing traffic counters. A normal account-list connection
also obtained the restarted Mac's new port without injected connection information or ADB
forwarding. The first updated Mac run exposed duplicate endpoint/identity rows; its observation
is retained, and the subsequent ownership correction still requires current product UI checks.

Original-file parsing remains WAVE/FLAC, whereas application capture declares 48 kHz stereo
Float32 PCM. Decoder support and strict hardware output eligibility are separate contracts.
The inspected current default Mac endpoint declared only mixable formats; strict output remains
enabled. Receiver failures now log the validated offered PCM fields to distinguish actual input
from assumptions about a music file. Neither a connected badge nor the tests above establishes
audible playback, all mainstream codec support, or bit-identical physical output.

The subsequent physical request confirmed 48 kHz stereo Float32 with 32 valid bits and 8 bytes
per frame, targeting the MacBook Pro speakers. The HAL format selector had collapsed an exact
representation available only as mixable into `formatMismatch`. Selection now retains the same
eligibility rules but distinguishes that case as `mixableVirtualFormat` / `output.mixing_required`.
Capability-read failures still propagate, and neither format conversion nor a fabricated
nonmixable flag is introduced. The recorded old selector failed the expected-diagnostic test;
152 related tests then passed with no compiler warnings. The current signed product also
reported the mixing requirement for the real phone request. Audio output remained rejected;
the capture service/projection ended while the authenticated control connection stayed alive.

Two same-signature phone updates recorded the earlier product displaying a connected header
after its peer TCP flow disappeared and the revised product displaying disconnected. These
observations did not normalize window activation; the qualification below limits their use. Normal Mac
application exit also released Android's connected-device foreground service before any phone
process restart. These results live in the Android workspace's
`artifacts/android-lan-background-20261025/`, including `output-issue-native-02`,
`old-mac-ownership-red.json`, `fixed-mac-ownership-green.json` and
`native-lease-after-mac-quit.json`. The Android full-app lint gate remains open: its retained
report has 44 dependency-update diagnostics and one unchanged `EmptySuperCall`, all in files
byte-identical to HEAD. The discovery-module lint and separate APK build passed; no lint rule
was disabled and no unrelated dependency upgrade was performed.

Qualification of the transport-closure UI observation: window activation was not controlled in
the two recordings above. A later raise refreshed a background window's header, so the retained
UI/transport discrepancy is not, by itself, causal runtime red/green proof of the ownership bug.
The exact-owner migration/retirement tests and code path are separate evidence. An additional
old-product foreground harness stopped before any connect action after misclassifying a stale
account-snapshot notice; it is retained as an invalid observation, not a product connection failure.

### ALAC qualification, 2026-10-25 — not yet a product capability

The Android shared metadata inspector now derives ALAC precision/rate from its specific config,
not placeholder AudioSampleEntry fields, and checks bounded packet/chunk/time tables. Its 69
tests and 126 existing WAVE/FLAC tests pass. This is a declaration/range inspector, not a codec
validation witness. Edited timelines, fragmentation, multiple tracks, external references and
unimplemented layouts remain explicit rejections; no sender or receiver advertises this profile.

Twenty-four real 16/20/24/32-bit mono/stereo ALAC files at 44.1/48/96 kHz decoded byte-exactly
through both Apple native comparators. A malformed packet ending before its samples was still
accepted with the advertised total frames, with 4,096 source frames observed as zeros in the
probe's zero-initialized buffers. Both native candidate qualification runs therefore fail.
The independent libavcodec comparator requires one actual decoded frame per declared packet;
it passes these 24 exact comparisons and rejects all four retained malformed files. This is a
bounded host experiment, not proof of arbitrary-input correctness or a shippable native package.
The installed host libraries were not added to product dependencies.

Receipts and original failures: `artifacts/alac-original-file-20261025/`. Reproduction, candidate
limits and remaining integration obligations:
[`Scripts/audio_alac_qualification/README.md`](../Scripts/audio_alac_qualification/README.md).
Held-reader identity, authorization, cancellation, codec ownership, platform SDK packaging,
capability negotiation, sender/receiver state machines and actual output acceptance remain open.
No ALAC-ready claim follows from metadata, file hashes, native success status or frame count alone.

### Source-locked ALAC C boundary, 2026-10-25 — host qualification only

`CSkyBridgeALAC` now provides a codec-only candidate C boundary over a signed, hash-locked
FFmpeg 8.1.3 source build. The owner must supply indexed packets from the same held verified
reader and independently validated per-packet frame counts. Integer precision, channel layout,
packet/frame limits, exact sequence, cancellation before publication, and clean completion are
checked. Errors release native resources and remain terminal. No product target or capability
advertisement is enabled, and the language-level lifetime/authorization adapters remain open.

Matched unmodified/patched decoder builds reproduced two additional counterexamples: upstream
strict error recognition still accepted an excessive zero run and excess data after an end
element, returning eight frames with zero frame-error flags. A source patch now propagates
those detected errors, element failures, and missing-channel failures in strict mode. The bridge
also requires a provider-contract symbol; an ABI-compatible unpatched library fails to link.

Both minimal macOS arm64 builds passed with zero compiler/linker warnings and dependencies
limited to libavcodec, libavutil, and libSystem. The frozen C boundary passed 53 cases, including
all 24 real ALAC integer-reference comparisons, cancellation, packet limits, sequencing, and
incomplete completion. The final build and qualification remove ambient compiler/header/library
search overrides; the C static analyzer reports zero diagnostics. Final receipts are under
`artifacts/alac-decoder-integration-20261025/clean-qualification-final/`. Initial runs that inherited
CPATH/LIBRARY_PATH and the build/dependency-gate failures remain preserved at
`artifacts/alac-decoder-integration-20261025/`. See
[`CSkyBridgeALAC/README.md`](../Sources/CSkyBridgeALAC/README.md) for the source lock, patch scope,
reproduction, licensing, and remaining platform/product gates. This does not supersede the
current mixable-only Mac output rejection or establish actual ALAC playback support.

### Apple ALAC container index and held-source binding, 2026-10-25

`SkyBridgeProtocolCore.AudioAlacFile` implements the same finite ALAC M4A metadata profile as
Android, with an additional sequential packet cursor. It derives precision/rate from the original
24-byte ALAC configuration, validates packet durations independently of decoded output, and bounds
every packet to media data. Table pages are bounded to 64 KiB; the source/metadata/box/packet limits
remain 2 GiB / 64 MiB / 4,096 / 4,194,304. Fixed/variable packet sizes, multiple chunk/time runs,
wide boxes and `co64` offsets are supported within the same limits. Unsupported layouts, short
reads, extra read bytes, malformed counts and cancellation remain explicit failures. Cursor EOF
means exact declared totals; it is not decoder EOF or playback completion.

`SkyBridgeAudioFile.AudioIndexedAlacFile.inspect` privately constructs the reader/declaration pair
inside the existing commitment-verified read scope, checks source identity and authorization, and
leaves descriptor ownership with the outer transfer. It never reopens the selected path. Both
task cancellation and the original authorization/source error are retained, including cancellation
triggered by the final authorization callback. The pair is not a decoded-file witness or a new
audio capability; no sender, receiver, codec negotiation, output policy or identity is enabled by it.

Evidence: `artifacts/alac-file-session-20261025/metadata-tests-04/` has 17 passing focused tests,
covering 24 real files and independent packet expectations, malformed/truncated/resource-bound
cases, retained-file identity and cancellation/revocation. The final-callback negative variant
fails when the post-callback cancellation check is removed. `product-audio-target-01/` records a
successful real `SkyBridgeAudioFile` build with `--disable-automatic-resolution -j 1`, without
warnings or dependency changes. `apple-sdk-source-checks-01/` records six source-level checks
for iOS arm64 and arm64/x86_64 simulator targets; these do not build/package the native decoder
or execute an iOS device. `fixture-reproduction.json` records identical re-export of all
49 M4A/PCM/manifest resources. Initial failed harness runs are retained separately. This index
increment alone did not establish native ownership, SDK packaging or actual playback. The next
increment below adds the Apple SDK/owner, without relaxing the mixable-output rejection.

### Apple ALAC native SDK and sequential owner, 2026-10-25

The pinned ALAC-only provider now builds as a dynamic C framework for macOS arm64, iOS arm64
and arm64/x86_64 simulators. Final packaged slices match their qualified input bytes. The six
public C ABI symbols are the only exports; codec internals stay private. Exact source, patches,
public verification material and notices accompany the locally admitted SDK. The root audio
module declares this dependency, and app packaging requires its provenance and notices.

`AudioAlacPCMDecoder` consumes `AudioIndexedAlacFile` rather than caller-supplied unrelated
metadata. It borrows the same verified source for each sequential packet, requires the indexed
frame count, and returns at most one native PCM frame. Native errors, missing output, source
mutation, revocation and cancellation remain terminal. Close from a synchronous authorization
callback marks the operation closed and defers destruction; no partial PCM/completion may escape.
Overlapping reads fail explicitly without queuing or poisoning the already active call.

Evidence is in `artifacts/alac-apple-sdk-20261025/`: four SDK slice builds, `package-03/` final
provenance/slice verification, 53 Mac C ABI cases, 25 focused Swift tests including all 24 exact
file comparisons, the real audio-module build, and iOS source/link checks. The first consumer
launch failed for missing runtime paths; executable-level relative paths now permit both direct
development execution and a relocated app bundle. A duplicate XCTest path warning was fixed
at the consuming target boundary. The existing libFLAC/liboqs/FreeRDP provenance checks pass.

These are SDK/component results. A complete decoded-file witness and bounded PCM read adapter,
file-offer/capability wiring, actual phone/background playback, strict-output device qualification,
and Android/Windows codec SDKs remain open. No ALAC-ready capability is advertised by this change.

### Complete ALAC validation and bounded PCM reads, 2026-10-25

`AudioValidatedAlacFile` binds a complete native decoder pass to the indexed file's held reader.
Validation discards each decoded frame, checks exact packet/frame/encoded-byte totals and clean
native EOF, and enforces a monotonic maximum of 180 seconds and four source hours. A valid prefix
followed by a malformed final packet cannot produce the witness. The witness does not authorize
output or permit reopening the pathname.

`AudioValidatedPCMReadSession` now provides the common sequential adapter for validated ALAC
and FLAC. It retains one native frame and a maximum 65,536-byte result, checks the held source and
authorization even for cached samples, and clears pending PCM and closes the decoder on terminal
failure. File ownership stays with the transfer. Cancellation is checked again after authorization
callbacks, including final witness/read publication. The existing FLAC API name is a source alias.

Evidence: `artifacts/alac-file-validation-20261025/receipt.json`. All 56 focused XCTest methods pass,
including 24 real ALAC reference comparisons and the existing FLAC regressions. An isolated copy
of the actual pre-change FLAC adapter/factory fails the two new final-callback cancellation tests;
the live source is never restored. The actual audio target builds, and the production dependency
closure passes six iOS device/simulator source checks without warnings. These tests open no output
device and do not establish phone-session, app-background or strict physical-output acceptance.

### Android-to-Mac original ALAC file integration, 2026-10-25

`audio_alac_file_receive_v1` extends the existing original-file capability without changing SBAU
message bytes. A sender still requires `audio_file_receive_v1` and the actual approved file carrier.
The extra capability is advertised only while the ALAC consumer is installed and that carrier is
available; capability replacement/removal retires the ALAC flag as well. It is not an output-device
compatibility promise. The initial ALAC profile is a finite, self-contained M4A with one mono/stereo
ALAC track and 16/20/24/32 valid bits. AAC-in-M4A, edited/fragmented/protected layouts and unsupported
channel layouts remain unsupported. Filename extensions do not select the decoder.

The Android original-file sender inspects the committed source, requires the authenticated peer's
ALAC capability before an offer, and sends the encoded bytes unchanged. Its native-validation wait
uses the existing bounded FLAC window. The Mac validates every declared packet and native EOF before
preparing output, then uses the shared bounded PCM adapter and existing exact-format pump. Malformed
decoded content maps to `contentMismatch`; provider/owner/allocation faults remain source failures.
No new account authority, transport, format conversion, output fallback or Bluetooth source support
is implied by this capability. In particular, it does not change application-audio capture formats.

The root Apple package has 155 passing selected XCTest methods with no warnings, covering real
encrypted file sockets and USB epoch-multiplex file channels with controlled authority and substitute
output. Exact PCM, source-frame totals, separately reported trailing padding, output rejection, drain
completion, malformed-tail rejection and capability retirement are checked. Initial resource-loading
and linker failures, and corrected partial-period padding expectations, are retained in
`artifacts/alac-original-file-integration-20261025/`. The Android repository retains its corresponding
metadata/wire/sender regression and app-compilation receipts under
`artifacts/alac-original-file-send-20261025/`. These are not device playback receipts. Current installed
apps, actual phone/background behavior, compatible strict physical output and iOS/Windows integration
still require separate acceptance.

### iOS original ALAC sender and application packaging, 2026-10-26

`IOSPreparedAudioFile` now inspects ALAC through the shared held-reader index adapter. It retains
the original file, digest, declared PCM format and exact frame count; it does not decode or convert
on the phone. The original-file sender requires the peer's specific ALAC receive capability before
offering the file, uses the bounded receiver-validation deadline, and verifies the output format
and playback receipt independently of the authenticated file receipt. File metadata uses `audio/mp4`.
The original-file picker includes M4A, but content inspection rejects non-ALAC sample entries.
Bluetooth still accepts only its qualified WAVE/FLAC source path and has a separate picker filter;
an ALAC source passed directly to that path fails explicitly. The existing foreground-only iOS
sender lifetime is unchanged and remains a product limitation.

Evidence: `artifacts/ios-alac-original-file-20261026/receipt.json`. The actual simulator app and
hosted tests build with Swift/Clang warnings as errors. All 72 selected tests pass, with zero skipped
or expected failures. Eight new or extended cases cover 16/20/24/32 valid bits, immutable container
bytes, peer capability, non-ALAC rejection, mismatched output declarations, receiver refusal and
validation timeout. Real TCP tests exercise encrypted file bytes and authenticated metadata/receipts
over both network and logical USB-return routes. Account authority, MAIN handshake and playback
reports are controlled test inputs; this is not physical USB, iPad, Mac/Windows interoperability or
speaker output acceptance. The test simulator is confirmed shut down after the run.

The runtime-log checker now recognizes XCTest's `Selected tests` outer-suite marker as well as
`All tests`; its single known IOSurface startup diagnostic must still precede the first applicable
marker. A post-start diagnostic remains a regression failure. The initially rejected log is retained.
Xcode also emitted an OS-build parsing diagnostic before test execution; its historical presence is
unconfirmed, and it is recorded separately from the empty XCTest runtime-warning result.

The Mac ALAC framework now uses the platform's versioned bundle layout. Its previously qualified
binary bytes, source archive and licenses are unchanged. Provenance hashes canonical local aliases
and checks their real payloads, rejecting escapes, cycles and unexpected aliases; all four native
dependency families verify. The native Mac app build, signed package and actual library loading
pass, and Android was updated in place with the same signing certificate. These packaging and
installation receipts are in `artifacts/alac-device-qualification-20261025/`. The Android-to-Mac
physical file check is still pending at the user's requested testing time; installation is not a
playback result. Strict output policy is unchanged, and a compatible physical output is still needed.

## Optional original-file output progress (2026-10-26)

Opcode **19**, `fileOutputProgress`, has an eight-byte big-endian unsigned source-frame
counter, restricted to `0...Int64.max`. The existing header, stream ID, size limits,
reserved-field validation and opcodes 1–18 are unchanged. The first increment added
only the Swift, Kotlin and C# structural codecs and their regression checks. The
runtime increment below installs specific producer/consumer roles; recognizing this
message alone does not enable native publication or iOS background execution.

The playback receiver's installed reporter must advertise
`audio_file_output_progress_report_v1`; the file sender's installed consumer must
advertise `audio_file_output_progress_receive_v1` on the same authenticated connection.
Both roles are required. Without either role the receiver emits no opcode 19, preserving
older peers' existing behavior. A parser or generic audio role alone is insufficient.

Runtime admission must bind progress to the exact accepted original-file stream,
current owner and finite source-frame count from the immutable file descriptor.
Progress is valid only after that stream's `outputReady` and native output start.
Counts must be nondecreasing and no greater than the source total; a repeated count
does not advance progress or refresh a deadline. Wrong-stream, wrong-phase, unnegotiated
or out-of-range reports fail the stream under its existing protocol-error and cleanup
rules. Retired streams retain the existing bounded mailbox retirement behavior.

The counter represents whole source frames consumed by the native output path, excluding
trailing silence. The Mac producer must use actual HAL callback submissions, not bytes
queued in the product ring. The Windows producer must use observed native retirement,
not its write/submission counter. These are output-pipeline observations, not proof of
physical sound or exact audible position. Wall-clock estimates, file-transfer byte
counts, decoder output and assumed elapsed playback are not substitutes.

Publication must coalesce newer observations into at most one pending progress update
and emit at most once per second, only when the observed source counter advances.
It must retain current authorization and the existing bounded control writer. Progress
cannot delay stop/terminal handling, grant flow credit, change PCM format, extend
absolute stream deadlines, or substitute for file integrity or `playbackComplete`.
Even a counter equal to the source total leaves the native drain and final completion
obligations open. A stalled output remains a failure under the existing output deadlines.

This supplies one prerequisite for user-initiated finite iOS background work. System
cancellation/expiration, source/channel cleanup, file-preparation progress and actual
device behavior still require implementation and validation before enabling that path.

### Device and codec evidence for this increment

The old Swift implementation rejects the new independent opcode-19 vector with
`unknownOpcode(19)`; the updated Swift suites pass 28 cases. Kotlin passes 26
audio/Opus wire cases plus Core/App compilation, and C# passes 13 portable wire
cases on Mac with zero build warnings/errors. The three copies of the original
31-vector fixture remain byte-identical. These checks qualify the structural
extension, not its future native publisher, negotiation or iOS background lifetime.
Evidence is in each platform's `artifacts/audio-file-playback-progress-20261026/`.

### Runtime ownership and progress consumers, 2026-10-26

The Mac live receiver now installs the reporting role only with an original-file
consumer and a usable file route. WAVE, FLAC and ALAC share the same native pump:
validated HAL source-frame observations update a single latest-counter slot. The
existing receiver tick and bounded writer publish at most once per second measured
from actual successful delivery. Critical controls supersede pending observations.
An admitted write remains owned until it settles, but stop closes native output
before waiting for that write; it cannot leave sound running behind a blocked sender.

The iOS installed file sender advertises its receiving role only when its file runtime
is ready. It accepts progress only on an accepted, output-ready original-file stream
from a peer that advertised the reporter role, and rejects regressions or counts
beyond the inspected source extent. Duplicate/zero counters neither advance the
published observation nor extend authorization, output or completion deadlines.
File receipt, exact output declaration and native playback completion remain separate
requirements, including when the reported counter reaches the entire source length.

Mac verification passes 170 relevant Swift cases; the pre-fix blocked-writer order
fails the native-close test. iOS build-for-testing and 100 hosted simulator cases pass,
including premature/unnegotiated, regressing/oversized and deadline-extension
counterexamples. Compiler warnings are treated as errors. The simulator diagnostic
gate passed with its one existing pre-test IOSurface diagnostic; the SDK build-number
diagnostic and loopback listener SO_NECP_LISTENUUID diagnostic were also present in
the earlier simulator run. The simulator was restored to Shutdown. Raw build/test
logs, exact inputs and the failed attempts are retained in
`artifacts/audio-output-progress-runtime-20261026/`.

At that checkpoint, this source increment had not replaced the normally connected
Mac/iPad application packages. The iPad's successful user-operated same-account connection is recorded
separately in `artifacts/ios-account-audio-device-20261026/receipt.json`; it is not a
runtime progress or background-playback result. At that checkpoint, iOS original-file
background work still required its actual system task owner, preparation progress,
cancellation/expiry handling and physical validation. The next section records the
subsequent implementation and its narrower physical evidence. The strict Mac output
rejection remains unchanged.

The latest signed iPad device build also passes 108 native hosted tests, with one
existing source-shape check skipped because repository files are not mounted in
the device sandbox. The skip is not functional audio or routing coverage. The
seven suites cover prepared files, original-file lifecycle/transfer, Opus sources,
account presence/matching and LAN route selection; controlled test authorities
and receiver receipts remain controlled inputs even on physical hardware.

Separately, the normal product was relaunched without XCTest mode. The user
selected the Mac through the iPad account-device connection button and reported
success; the running Mac then showed the same stable iPad identity as network
connected with its authenticated Q-Periapt session. Android USB stayed connected.
This validates the account entry and server route on these devices without manual
connection information. It does not establish background playback, file-to-speaker
output, physical fidelity or Windows behavior. Legacy unverified pairing rows
remain visible separately and were not promoted or deleted. Device build/test
and Mac UI receipts are in `artifacts/ios-account-audio-device-20261026/`.

### iOS finite original-file background execution, 2026-10-26

The file-selection service now owns a `BGContinuedProcessingTask` on iOS 26 or later
when the selected authenticated channel advertises native output-progress reporting.
Each operation uses a unique identifier and the immediate `.fail` submission strategy.
Both actual system launch and successful submission are required before sending an
offer. The iOS 27 adapter uses the asynchronous SDK submission API off the main actor.
Older systems and peers without this capability remain explicitly foreground-only;
Bluetooth file sending retains its existing foreground restriction. App and project
generator configuration both declare `processing` and the same permitted identifier
prefix. The design follows Apple's
[continued-processing contract](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados).

The service retains the file operation and system task across presentation/background
changes. Cancellation, expiration, a rejected submission or a bounded launch timeout
stop actual work. Cleanup retains ownership of a late, noncooperative submission;
returning from a timeout cannot stand in for its eventual completion. Native expiration
is recorded before the actor hop, preventing a queued expiration callback from racing
a successful completion. Neither background admission nor progress renews account or
stream authority. Force-quitting the app is outside the continuation guarantee.

System progress combines four work components: actual held-descriptor hash bytes,
transfer bytes, authenticated native source frames, and verified final receipt plus
owned cleanup. Unknown totals stay incomplete; counters cannot regress, overflow or
exceed their inspected extents. Reaching the last output frame cannot replace the
receiver's final completion acknowledgement. The display describes work progress,
not audible playback position or a duration estimate. No silent audio is used to keep
the app running.

Verification in `artifacts/ios-original-file-background-20261026/` includes 106 shared
core cases, 226 affected hosted simulator cases, and three further snapshot lifecycle
checks after repairing window teardown. The earlier scrolling failure is preserved:
large-text lazy rows grew after the fixture's fixed number of jumps. The test now
waits for two stable measured-bottom observations within a finite deadline, retaining
its actual-bottom assertion. Snapshot teardown removes the root while its window is
still visible and awaits UIKit's disappearance callback before hiding the window.
The failed initial teardown revision and earlier simulator-launch/diagnostic failures
remain in the evidence directory; they are not reclassified as successful tests.

On the physical wired iPad running iPadOS 27.0.1, one hosted SDK test used the real
`IOSContinuedAudioTaskScheduler`: the system admitted the task, the held file reader
hashed 8,388,652 bytes, the digest matched, and the source closed before intentional
cancellation completed. This checks native admission and ownership, not receiver
delivery or sound. Its machine-readable attachment explicitly records
`backgroundSwitchTested=false`, `audioPlayed=false`,
`systemExpirationCallbackTested=false` and `receiverReceiptReceived=false`.
The signed package preserves the existing bundle/team identity and was relaunched
normally without XCTest environment variables. Physical app-switch persistence,
native system-triggered expiration, complete original-file playback, output fidelity,
and Windows behavior still require their own evidence. The incompatible strict Mac
output is not relaxed by this implementation.

The Mac receiver was subsequently rebuilt and packaged as local test build
`20261026135704`, with its existing Developer ID, bundle identity and entitlements.
The running executable hash matches the verified package and contains the output
progress reporting capability. The normal device-list action reconnected the same
iPad identity without entering a connection code; the Mac UI displayed an authenticated
Q-Periapt session. That is a new-package connection receipt, not observation of a
running audio progress stream. The physical iPad SDK admission result and this normal
product connection are separate checks, not a combined background-playback result.

### Physical iPad background file rejection flow, 2026-10-26

The user selected the staged, previously verified 48 kHz / 24-bit stereo ALAC file
through the normal iPad app's file picker and reported returning to Home. The Mac
then still displayed the original-file approval for that same authenticated iPad.
After approval, the receiver displayed the source format and its native log recorded
`phase=preparing reason=unsupportedOutput cause=output.format_mismatch`, with six
source bytes per frame. The user returned to SkyBridge and confirmed the matching
receiver-format rejection instead of a disconnected or indefinitely waiting page.

This is a real product transfer/rejection case. On the compiled receiver path, a file
artifact is delivered only after offered length and digest verification, and ALAC
format publication follows complete indexed-packet decode validation. It does not
establish successful output or audible fidelity. Device OS logs could not be read
without additional system authentication, so the user's Home action and subsequent
product observations are not presented as an independently captured OS lifecycle trace.

Post-test inspection showed a secure connection to the same iPad, but its label had
changed from USB to network. Exact session-owner and file-carrier continuity were
not observed. An informational PIB-1 code page was also present and was dismissed
without approving a new identity; its trigger is unresolved. These observations
remain follow-up work, not proof of uninterrupted USB playback. Screenshots, scoped
native failure log, fixture readback hash and evidence limits are retained in
`artifacts/ios-file-background-product-20261026/receipt.json`.

### Per-operation audio connection attribution, 2026-10-26

`P2PAudioCarrier` and its authenticated audio channel now require an immutable
control-transport value supplied by their actual owner. An `NWConnection` does
not imply network transport: Apple USB multiplexing also uses that representation.
Native USB adapters supply USB explicitly, and inbound network adapters supply
network explicitly. This does not change the wire protocol or authorize a route
change.

The receiver takes that value only when it acquires the playback owner and keeps
it with the terminal result. A concurrent rejected request cannot overwrite it.
The playback window displays this operation's device connection, and the native
failure diagnostic includes the same value. Bluetooth media mode remains a
separate field; a control connection does not describe the Bluetooth media carrier.
This removes dependence on a later device-list snapshot when reporting an audio
operation. It does not explain or repair the earlier USB-to-network transition.

The seven affected core suites passed 191 tests with warnings treated as errors,
including USB represented by `NWConnection`, owner retirement, and competing
requests retaining the active operation's connection. The initial compile failure
from an OSLog autoclosure capture was corrected and its failed log retained.
Release package `20261026145752` built successfully with unchanged recorded source
inputs; its Developer ID, bundle identity and entitlements were checked against
the preceding package. The running executable hash matches the new package.

The app-owned USB connection command then authenticated the same physical iPad
against its existing protocol fingerprint, with no network fallback. Both the
command receipt and normal Mac UI reported USB with the existing Q-Periapt suite.
The subsequent user-operated iPad file request reached the real audio window with
`network` as its immutable connection value. Its native diagnostic also recorded
`phase=awaitingApproval reason=timedOut controlTransport=network`; source PCM was
not yet validated. The approval window was behind the main UI, and the operator
did not reach it before its deadline. This is an approval-stage timeout, not an
observed file-transfer, decoder or background-runtime failure. It verifies the new
per-operation display on a real request but does not validate a USB audio transfer.
The user subsequently confirmed pressing the iPad's Connect Device action before
selecting audio. The physical USB device was still enumerated afterward, but the
iPad's exact authenticated-session state immediately before that action was not
captured. This is not proof of an automatic carrier switch or of a particular
connection-reuse defect. The strict output requirement remains unchanged; successful audible
output still needs its own compatible-device evidence.
Commands, logs, source hashes and the scoped change are retained in
`artifacts/ios-audio-route-continuity-20261026/`.

### iOS finite Bluetooth-file background execution, 2026-10-26

The Bluetooth selected-file service now uses the same owned continued-processing
task as the original-file service on supported systems. It requires both system
submission and the actual launch callback before the sender runs. Its preplanned
job survives the immediate app-switch transition; cancellation, rejection, expiry
or a launch deadline stops the exact sender and joins cleanup. Older systems retain
the explicit foreground-only behavior. The existing account lease, paired MAIN,
single-use Bluetooth child and receiver playback approval remain independent gates.

The central-role adapter now declares `bluetooth-central` in both app and generator
configuration. Apple documents that this declaration allows central-role background
event handling; it alone does not guarantee sustained execution. The user-initiated,
finite workload uses the existing `BGContinuedProcessingTask` request and its visible
system cancellation/progress interface. This is an implementation candidate for
physical background qualification, not a promise of uninterrupted radio execution.

Background work has three measured components and a separate final receipt/cleanup
component. Bluetooth uses completed source preparation, confirmed packet writes,
and receiver-retired packet contributions. The finite packet total is derived from
the actual encoder instance's pre-skip plus the inspected converted source extent;
the completed encoder counts must agree. No timer estimates progress or invents
retirement. The existing validated PlaybackComplete can account for final drain
when the last credit is coalesced, but cannot report system-job success before the
End write and owned cleanup complete. Unknown, regressing, overflowing or changed
totals fail; one task cannot switch between original-file and Bluetooth accounting.
These are work units, not audible position or proof of original-format fidelity.

The old implementation failed the newly added immediate-background service case:
it stopped the Bluetooth operation without submitting the requested system job.
After the change, ten affected suites passed 232 cases with zero failures or skips.
They exercise native file reads, conversion/Opus, framing/AEAD and stream workers,
with controlled system-task, radio and output acknowledgements. Expiry, rejected
submission, failed close, foreground-only fallback and final-receipt requirements
are covered. Both complete simulator and iPhoneOS builds passed warnings-as-errors;
the signed native bundle retains the same application/team identity. It has not
yet replaced the installed iPad app or run this Bluetooth background flow on hardware.
The single pre-test IOSurface diagnostic also occurs in the retained red run and
passes the existing bounded simulator diagnostic rule; no rule was relaxed.
Evidence and hosted SwiftUI snapshots: `artifacts/ios-bluetooth-background-20261026/`.


### iPad selected-entry USB reuse and background receipt, 2026-10-26

A normal-product XCUITest runner, authorized for the connection/audio workflow,
attached to the existing physical iPad process without fixture arguments or a
state reset. With a network session, the account Connect action returned success.
With an authenticated USB session in the same process, it instead returned an
identity-mismatch error while the Mac retained its USB owner. The selected-entry
code compared the inbound runtime storage alias to the stable selected SOA ID
before consulting the authenticated session. An endpoint-keyed inbound owner is
legitimate only when its current Finished binding matches the selected stable ID,
fingerprint and account signing algorithm.

Reuse now checks that binding on the exact current owner and retains the receipt's
socket generation/session. An alias without authenticated ownership still cannot
become a fresh dial target. The original code failed the new reuse regression with
identityMismatch; 109 focused cases then passed, including identity substitution,
missing authority, unowned aliases and existing lease/audio tests. No trust,
identity, capability, TTL or output-policy requirement was relaxed.

The signed iPad candidate was installed in place, retaining its account and paired
identity. The repeated account action succeeded while the Mac retained the same
USB device reference. The real document picker selected the existing quiet ALAC
fixture; the system background task became active before returning Home. Mac
approval occurred afterward, and the receiver validated 48 kHz, stereo, 24-bit PCM
on the USB operation. The built-in output rejected that exact format, and the same
iPad process retained the precise unsupported-output result. This is physical
USB/background delivery and final-error reporting, not successful audible output.

A separate post-terminal failure remains: the Mac later retired the USB control
session with classicTransferSessionLeaseUnavailable, and the resumed iPad restored
a network connection. The test also recorded a network-to-USB replacement failure
until the existing network session was explicitly disconnected. These cases are
retained as follow-up defects rather than counted as stable connection acceptance.
Evidence: `Artifacts/ios-selected-session-reuse-20261026/receipt.json` and
`Artifacts/ipad-audio-ui-20261026/`. The installed candidate also contains the
preceding finite Bluetooth-background implementation; its physical radio/background
qualification remains open.

### iPad heartbeat cadence and suspended-resume counterexample, 2026-10-26

The iOS heartbeat timer previously skipped publication whenever any control frame
had arrived recently. Mac RTT probes could therefore starve the metadata heartbeat
that refreshes the bounded file-session registration. The timer now keeps its
20-second cadence while preserving the exact socket/session checks and rekey gate.
The cache's 120-second lifetime and its prohibition on reviving expired leases are
unchanged. The iOS build and 109 focused regressions passed; an earlier test-host
launch failure is retained separately.

The installed normal iPad process retained one authenticated USB carrier through
152 seconds of picker dwell, then selected the existing ALAC fixture and returned
Home with its system background task active. The receiver delivered the precise
unsupported-output result at 17:07:10 UTC, and the same iPad process retained that
result. However, after the task ended and iOS suspended the process, resuming it at
17:10:45 caused the Mac to close the carrier with
classicTransferSessionLeaseUnavailable. This is a failing suspension/resume case,
not stable-background acceptance. An authenticated CLI snapshot before resume had
described the carrier without proving its derivative file-session lease was live.
Evidence: `Artifacts/ios-heartbeat-liveness-20261026/receipt.json`. Recovery must use
fresh authentication; a heartbeat alone must not resurrect the expired file owner.

### Fresh control authentication after mobile suspension, 2026-10-26

The Mac control owner now starts one normal outbound rekey when an authenticated
heartbeat cannot refresh its derivative file-session lease. The expired lease is
not revived. The current carrier reserves an exact handshake generation before
returning to its receive loop, which remains available for handshake responses.
Audio is withdrawn until fresh Finished/pairing admission. The existing crypto
policy remains in force. A 90-second operation deadline, normal driver deadlines,
and disconnect cancellation bound the work; a failed recovery closes the owner
instead of restoring the expired file session. USB preflight retains its exact
registered owner while status is authenticating, without choosing a LAN fallback.

98 focused regressions passed, including current/stale keys, duplicate recovery,
disconnect, cancellation, existing TTL and audio ownership. The signed Mac package
retains the previous application identity and entitlements. On the physical iPad,
the ordinary account entry reused USB, the real picker selected the existing ALAC
fixture, and its background job was ready before returning Home. After the first
unsupported-output receipt, a 150-second observation was followed by a resume from
the actual suspended state in the same product process. At 18:48:01 UTC the Mac
started fresh authentication; at 18:48:04 it completed strict Q-Periapt negotiation.
The iPad displayed connected and selected the same file a second time. Mac again
received it over USB with 48 kHz/stereo/24-bit PCM, and the iPad retained the second
precise unsupported-output receipt while connected at 18:50:59. No address input,
QR, trust reset, or product restart was needed for this recovery.

This qualifies that physical USB suspension/resume and repeated original-file
delivery path. It does not qualify audible output on the incompatible built-in
speakers, Android recovery, Windows, or physical Bluetooth background operation.
The observation also exposed a separate metadata issue: presence refresh adopted
a discovered LAN address and the CLI listed duplicate discovery records for the
same stable peer, although the actual carrier and both file operations remained
USB. That presentation/routing metadata issue and explicit network-to-USB
replacement remain open. Evidence:
`Artifacts/control-lease-reauthentication-20261026/receipt.json`.

### USB presence address and device selection, 2026-10-26

The original outbound presence projection preferred a discovered LAN address and
file port even for a USB carrier. An extracted unchanged projection failed six
assertions covering Apple and Android cable addresses. USB publication now retains
the carrier address and supplies no TCP file-route descriptor; the current MAIN
owner remains responsible for USB file channels. Network projection still uses
its resolved/advertised TCP route. Nearby selection also retains one representative
per exact authenticated connection, with cable targets first; names, IPs and
unauthenticated device claims do not merge distinct owners.

171 relevant tests passed. The signed Mac package was then tested with the same
normal iPad process, account entry and ALAC fixture. Both original-file operations
arrived over USB. After a 150-second post-terminal dwell, the suspended iPad resumed
and completed fresh strict Q-Periapt authentication; the presence address remained
USB and the nearby list contained exactly one device. A second suspended resume
also reauthenticated successfully. The final sender view retained the precise
unsupported-output result and showed connected. This closes the observed USB
address/selection defects, without claiming audible output on the built-in speaker.
Evidence: `Artifacts/usb-presence-projection-20261026/receipt.json`.

A final main-window observation exposed a separate dashboard inconsistency: the
encrypted header was current but the aggregate device counter displayed zero and
the discovery row still offered Connect. Dashboard aggregate metrics must not be
overwritten by remote-desktop-only metrics, and connected row presentation must
match the current authenticated device identity and fingerprint. That UI correction
is tracked separately from the verified carrier and file-delivery result.

### Dashboard USB connection presentation, 2026-10-26

Remote-desktop metric ticks no longer overwrite aggregate discovery, transfer and
session counts. Those counts update synchronously from their existing owners.
The session card is explicitly labelled Remote Sessions. A discovery row displays
Connected only when its stable identity and protocol fingerprint match the current
authenticated connection and presence; USB then replaces the IP/Wi-Fi hint in that
row. An IP address alone never establishes connected state.

17 dashboard regression tests passed with warnings treated as errors. The signed
Mac package was launched and connected to the existing paired iPad through the
normal USB Management Connect button, without typed addresses, keys or a CLI connect
operation. Main Dashboard displayed one discovered device, USB and Connected. The
iPad account entry reused that USB carrier. Disconnecting through the normal iPad
detail page retracted the Mac encrypted header and connected row, and reconnecting
through USB Management restored both. The discovered-device count remained one
while a live discovery observation remained after disconnect; this count is not an
authenticated-session count. All iPad steps retained the same normal product process.

The package retains the exact core/nearby-runtime inputs from the qualified USB
presence package above. No additional playback result is claimed by this UI check.
Strict audible output still needs compatible hardware. Inbound network row
presentation and explicit inbound-network-to-USB replacement remain outside this
qualification. Evidence: `Artifacts/dashboard-control-status-20261026/receipt.json`.

## 2026-10-26 iPad same-account route and preflight error qualification

A physical iPad failed to connect through the normal account IP action, but the
same package completed strict Q-Periapt through the identity-matched nearby
Bonjour/AWDL action. The account view previously selected its published IP action
even when the exact nearby identity and service interface were available. It now
prefers the existing nearby account action in that case; the published route
remains available when there is no matching nearby action. Account identity,
fingerprint, Finished and trust checks remain unchanged.

Preflight also caught typed transport failures from identity-binding bootstrap
and eventually presented them as missing post-quantum key material. Both PIB and
SKR now preserve transport, cancellation and account-selection failures; real
identity failures retain their existing recovery policy. The device-detail state
records the same original error instead of replacing it with generic retry text.

The old classification failed eight assertions across four focused cases. The
final iOS simulator suite ran 119 cases with zero failures; the signed native
package retained the previous entitlements. A cold normal account-button click
then established strict Q-Periapt over the observed AWDL route, without a QR code
or typed connection data. Before the route change, the corrected failure message
was also observed as a network timeout on the physical iPad.

This is connection qualification, not network audio playback acceptance. Both
foreground and background file attempts failed after Mac approval. The foreground
trace reached all chunks, hash verification, deep scanning and successful receipt
send, then failed before the audio consumer received the private artifact. The
product file listener cancelled its own receive task when normal file settlement
closed the socket. Existing direct-manager socket tests bypassed that listener.
The expired first foreground approval is retained separately and is not counted
as a file-transfer result. Follow-up regression and native qualification are in
`Artifacts/network-audio-file-settlement-20261026`.

Explicit network-to-USB replacement also produced `already_connected`. The label
can originate in the local outgoing arbiter as well as a peer rejection, so it
does not establish a remote-side cause. This replacement remains unqualified.
Evidence and source deltas: `Artifacts/usb-route-replacement-20261026`.

## 2026-10-26 network original-file settlement

The file listener and manager now share the same native byte-channel owner. Only
the consumer's normal completion close, after its authenticated receipt write,
avoids cancelling that receive task. The owner still checks cancellation and
authorization after native close and before delivering the private artifact.
Unexpected native failure or cancellation still cancels reception; the terminal
receive task releases ordinary connection admission after its work drains. The
callback weakly references the byte-channel owner to avoid a native-handler cycle.

An added loopback test uses the product listener's actual admission and state
callback, wire crypto, file manager and private storage. It failed on the old
implementation with the same `sourceFailed` result seen on the physical Mac.
Normal delivery and unexpected-close/listener-stop controls then passed with the
fix. The related suite passed 170 cases, with warnings treated as errors. Four
existing source assertions were updated to follow cancellation/read operations
already moved into the byte-channel adapter before this change; their original
failure and before-source evidence are retained. The new suite does not establish
an account/MAIN handshake or qualify a physical output device.

The signed Mac package retained the prior Developer ID and entitlements. Two
physical iPad-to-Mac network attempts used the normal same-account button and
native file picker: one returned Home before Mac approval, and one stayed in the
foreground after reconnecting. Both completed file hash verification and receipt
send, delivered the private artifact, and exposed the original 48 kHz, stereo,
24-bit ALAC decode format. Both then stopped at strict output preparation with
`output.format_mismatch`, and the iPad displayed the output-format refusal. This
qualifies file delivery and final failure feedback, not audible playback.

The background attempt also exposed a separate control-lifecycle counterexample:
the iPad detail displayed a receive-header failure and Mac presence subsequently
retired the MAIN connection. The next normal account-button connection succeeded;
automatic recovery and uninterrupted background control remain unqualified. The
foreground repeat showed Connected after the final audio refusal. Evidence:
`Artifacts/network-audio-file-settlement-20261026`.

## 2026-10-26 iOS control recovery after suspension

An authenticated outbound read failure could retire its exact connection before
the native state callback ran. The later callback was correctly treated as stale,
but the read-side cleanup had never scheduled recovery. This made automatic
reconnection depend on callback ordering. A deterministic test through the actual
manager reproduced the missing read-first retry; the state-first control passed.
The old implementation also ignored the existing Auto Reconnect setting.

Read-side cleanup now hands classified transport loss to the existing bounded
retry episode only for the exact previously authenticated owner, after retiring
its resources. A replacement owner, explicit user disconnect, disabled setting,
trust suppression, protocol failure or Swift task cancellation prevents that
handoff. Native ECANCELED is not itself proof of a user stop; the separate owner
and intent checks apply. Recovery performs a fresh normal handshake, retains the
eight-attempt backoff budget, and never revives expired keys or authorization.
Inbound USB receive paths retain their existing behavior. Outbound errors are
shown in the current device state; successful recovery no longer leaves a stale
inbound-error banner. Actual inbound protocol failures remain visible.

The final simulator suite passed 150 cases with zero failures and unchanged
inputs. The isolated retry-budget suite passed 16 runtime cases and seven source
wiring checks. The normal diagnostic injection was retained. Two cold-start
timeouts and one host-launch failure executed no test cases; their results remain
alongside the unchanged passing rerun, rather than being counted as passes.
The final native build and signature/entitlement checks passed.

On the physical iPad, the final package used the normal same-account button and
completed strict Q-Periapt authentication. After returning Home at 22:56:09 UTC,
Mac retired the old control owner at 22:56:52. XCUITest observed the app suspended
before activating it at 22:57:40. Without another Connect click or product restart,
a fresh strict Q-Periapt handshake completed at 22:57:48. The device detail then
showed Connected without the stale failure banner. The same process selected the
existing ALAC fixture, returned Home before Mac approval, and completed file hash
verification and receipt send at 22:59:27. Mac identified 48 kHz/stereo/24-bit PCM
and refused the incompatible output. At 22:59:50 the resumed iPad showed that
precise refusal while remaining connected. Two earlier native cycles are retained
as supporting evidence; their stale-banner observation led to the final UI fix.
The post-file resume also completed fresh strict authentication at 22:59:55 and
continued sending heartbeats through 23:02:35. A final UI observation at 23:04:05
retained Connected and the output refusal without a stale read-failure banner.

This qualifies the observed suspension/resume, fresh authentication and subsequent
background file delivery. It does not promise a permanently live idle connection
while iPadOS suspends the app, nor establish continuous audible playback. A
compatible strict-output device, Windows physical qualification and explicit
inbound-network-to-USB replacement remain open. Evidence:
`Artifacts/ios-control-recovery-20261026/receipt.json`.

