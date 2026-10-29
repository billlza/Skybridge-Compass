# USB link record profile v2

Status: candidate record codec, 2026-10-23. Kotlin and shared Swift implementations
exist, alongside the [candidate epoch state engine](usb-link-epoch-profile-v2.md).
Native producers/consumers still use the previous raw-Yamux route. The record
codec alone is **not** an epoch exchange, native recovery mechanism, security
handshake, or audio capability. Do not activate v2 without the gates
at the end of this document.

## Why a physical record boundary is necessary

A real Android/Mac AOA probe received old PING and stream-reset frames after both
local native owners had closed/reopened. Local resource release does not empty
an accessory's queues. Restart can also leave the reader in the middle of an old
record, or leave a complete old prefix whose writer stopped before finishing it.
A new Yamux object cannot safely treat those bytes as a new reliable connection.

The record layer separates byte alignment from epoch admission. The existing
Yamux and MAIN bytes remain opaque payload; their semantics are unchanged.
Fresh transport nonces are not device identities, account grants, authentication
keys, or permission to renew an offline lease.

## Wire record

This profile version is distinct from the Android Open Accessory protocol
version returned by vendor request 51, and from the application/SDK version.

All offsets below refer to the unescaped record. Multi-byte length is big endian;
FCS-32 is little endian. Payload bytes are copied unchanged.

| Offset | Bytes | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII `SBUL` |
| 4 | 1 | Profile version, exactly 2 |
| 5 | 1 | Kind, 0 through 5 |
| 6 | 32 | Sender's current transport nonce; never all zero |
| 38 | 32 | Recipient nonce, or all zero for OFFER only |
| 70 | 2 | Payload length |
| 72 | length | Opaque payload |
| 72 + length | 4 | FCS-32 over the preceding header and payload |

| Kind | Intended direction | Payload |
| --- | --- | --- |
| 0 OFFER | Host/client nonce to zero recipient | Empty |
| 1 SELECT | Phone/server nonce to host/client nonce | Empty |
| 2 ACCEPT | Host/client nonce to selected phone/server nonce | Empty |
| 3 READY | Phone/server nonce to host/client nonce | Empty |
| 4 DATA | Either direction, current nonce pair | Opaque bytes |
| 5 CLOSE | Either direction, current nonce pair | Empty |

OFFER/SELECT/ACCEPT/READY/CLOSE have zero payload. DATA requires 1–16,384 bytes.
Nonzero sender and recipient must differ. The codec validates this syntax; it
does **not** implement or validate the intended exchange ordering above. In
particular, decoding an old DATA record is not permission to deliver it to Yamux.

Each record is enclosed by `0x7e` flags. `0x7e` and `0x7d` inside the header,
payload or FCS are escaped as `0x7d` followed by the byte XOR `0x20`. This profile
has no ACCM and rejects other escape pairs. It uses reflected IEEE FCS-32 with
polynomial `0xedb88320`, initial state and final XOR `0xffffffff`.
[The octet-transparency and FCS procedures](https://www.rfc-editor.org/rfc/rfc1662.html)
are drawn from RFC 1662; this header is a SkyBridge profile, not a PPP packet or
an implementation of PPP negotiation. FCS detects framing damage; it supplies
no cryptographic authentication.

## Bounded decoding and explicit startup recovery

The decoded record limit is 16,460 bytes. The worst-case encoded limit, including
two flags, is 32,922 bytes. A new decoder can discard/count up to 32,921 bytes
before its first flag to align after a partial old read. Its retained frame
buffer stays within the decoded limit; this is not a whole-application heap or
throughput measurement.

The default mode is strict: a malformed complete record retires the decoder.
An explicitly constructed STARTUP decoder additionally allows at most eight
bounded rejections due to truncated records, body-length mismatch, bad FCS or
malformed escaping. Each returns a typed Discarded event with its reason and
encoded-body byte count. It does not disappear as an empty successful read.
Malformed escaping waits only within the encoded-record limit for the next
flag. Unknown magic/version/kind, invalid nonce semantics and capacity failures
remain terminal; there is no implicit downgrade to the old raw wire.

`seal()` irreversibly switches to strict mode and requires a complete record
boundary. Calling it on partial input is terminal. The future epoch owner must
seal only after its fresh exchange is confirmed; the parser cannot make that
authority decision. A sealed decoder cannot discard damage and resume payload
processing. After any terminal failure it preserves the first failure and
rejects later input.

Per-record limits and the eight-discard limit are insufficient by themselves:
the I/O/epoch owner must also bound whole-startup elapsed time, total bytes,
valid/stale records, handshake candidates, retransmissions and output queues.
It must use one reader/writer, preserve native packet tails, and split encoded
records into native writes no larger than 16 KiB. Encoded records can span native
transfers; authenticated inner data frames can span records. Physical EOF or
cancellation always retires the carrier and cannot stand in for an authenticated
file receipt or completed audio drain.

## Required before native activation

1. Implement an explicit fresh exchange with locally generated unpredictable
   nonces, dispatch/confirmation ordering and a monotonic whole-startup deadline.
   Old complete DATA/CLOSE/handshake records must be rejected or quarantined
   under a finite startup budget before any inner parser sees their payload.
2. Cover peer replacement while an old session is active, callbacks racing native
   write completion, local/remote cancellation, repeated startup messages and
   process restart. A replacement must retire existing stream owners and grants
   before publication, and wait for actual native cleanup before reopening.
3. Update both native runtimes and the AOA profile marker together. Version 1
   must not be silently interpreted as v2, or vice versa. Remove the current
   Mac reattachment guard only after same-attachment physical recovery passes.
4. Re-run Kotlin/Swift/native interoperability with partial reads and writes,
   delayed/replayed old frames, flow pressure, canceled writes, and cleanup
   failures. Current process codec tests are not those native acceptance results.
5. Keep signed PIB/SKR, Finished, selected identity, finite same-account offline
   leases and strict output gates unchanged. USB file/audio admission remains
   closed until the complete authenticated transport and playback paths qualify.

The synthetic interrupted-write counterexample, independent Python/zlib vectors,
strict negative control and startup recovery result are retained under
`artifacts/android-usb-link-records-20261023/` in the Android worktree. The first
candidate could align a partial old read but rejected a partially written old
prefix followed by a new OFFER. The revised explicit startup mode reports that
rejection and recovers the next complete record; strict mode continues to fail.
