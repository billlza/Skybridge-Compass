# ALAC original-file qualification

This is an isolated, silent experiment. It neither opens an output device nor changes the
product's advertised formats. It does not test an authenticated phone session, USB, Bluetooth,
speaker fidelity, or native Windows/Android/iOS execution.

The fixture generator creates WAVE source samples with deliberate least-significant bits,
positive/negative extrema, channel differences, and a partial final packet. Apple's `afconvert`
encodes 24 M4A cases: 44.1/48/96 kHz × mono/stereo × 16/20/24/32 valid bits. Independent FFmpeg
decoding must match the original canonical integer PCM before a fixture is accepted. 20-bit
PCM uses a 24-bit container with high alignment, not an implicit Float32 conversion.

Use fresh output directories, from the Apple repository root. Run one build/test task at a time:

```sh
python3 Scripts/audio_alac_qualification/make_fixtures.py --output artifacts/alac-fixtures --ffmpeg /opt/homebrew/bin/ffmpeg
python3 Scripts/audio_alac_qualification/build_probes.py --output artifacts/alac-comparators
python3 Scripts/audio_alac_qualification/run_native.py --fixtures artifacts/alac-fixtures --probe artifacts/alac-comparators/native-probe --output artifacts/alac-extended
python3 Scripts/audio_alac_qualification/run_native.py --fixtures artifacts/alac-fixtures --probe artifacts/alac-comparators/native-probe --output artifacts/alac-packet --packet
python3 Scripts/audio_alac_qualification/run_native.py --fixtures artifacts/alac-fixtures --probe artifacts/alac-comparators/strict-packet-probe --output artifacts/alac-strict-packet
```

The C comparator requires existing `pkg-config`, libavformat, libavcodec and libavutil development
libraries. The builder does not install them. Installed host libraries are experimental inputs,
**not a reviewed or shippable product SDK**. Their versions and hashes are retained. A product
integration still needs a source-locked, platform-qualified build, licensing/packaging review,
bounded committed-source callbacks, authorization, cancellation and owner cleanup.

## Observed result on 2026-10-25

Repository index and future decoder fixtures can be reproduced from the accepted generator
receipt, using new output paths:

```sh
python3 Scripts/audio_alac_qualification/make_packet_index_vectors.py --fixtures artifacts/alac-fixtures --ffprobe /opt/homebrew/bin/ffprobe --output artifacts/alac-packet-index-v1.json --evidence artifacts/alac-packet-index-reference
python3 Scripts/audio_alac_qualification/export_decoder_fixtures.py --fixtures artifacts/alac-fixtures --output artifacts/alac-decoder-v1
```

The first command records an independent demuxer's packet offsets, sizes and durations without
adding that demuxer to the product. The second verifies the original M4A/reference hashes and
exports exact high-aligned integer PCM in the smallest 16/24/32-bit container; it refuses any
discarded nonzero precision bits. These generated extreme samples are for silent comparisons.
The 2026-10-25 export reproduced all 49 repository files byte for byte. Apple container/held-reader
tests and the actual audio module build are recorded under
`artifacts/alac-file-session-20261025/`; this evidence does not enable ALAC product playback.

The real native owners, complete decoded-file witnesses and bounded PCM adapters can be checked
with production-source and SDK snapshots, without opening an audio device:

```sh
python3 Scripts/audio_alac_qualification/check_file_session.py --output artifacts/lossless-file-session-check
```

This requires the pinned `alac` and `libflac` SDKs already in `Sources/Vendor`. The harness runs
one build/test job, strips external compiler/loader overrides, records input hashes and checks
the named XCTest results. It does not substitute a decoder or count an empty Swift Testing run.

Evidence: `artifacts/alac-original-file-20261025/`. Final builds use Swift 6 with compiler/linker
warnings as errors, or C17 with `-Wall -Wextra -Werror -Wpedantic`.

| Comparator | Exact positive files | Rejected malformed files | Qualification |
| --- | ---: | ---: | --- |
| `ExtAudioFileRead` over immutable read callbacks | 24/24 | 3/4 | Failed |
| `AudioConverterFillComplexBuffer`, isolated per packet | 24/24 | 3/4 | Failed |
| libavcodec with a mandatory decoded frame per declared packet | 24/24 | 4/4 | Passed this bounded experiment |

The counterexample changes the first packet's element type to `ID_END`, before its advertised
samples. Both Apple comparators return success and 4,817 total frames; the first 4,096 frames
are zeros rather than the source samples, while the final 721 frames match. These probes used
zero-initialized output storage; they do not establish whether the installed codec explicitly
filled silence or left part of that storage unwritten. The exact source and bad-file hashes,
native return values, output bytes and comparison failures remain in `final-extended/` and
`final-packet/`. Do not convert those failing experiment exits into acceptance.

The strict C comparator rejects the same input when `avcodec_receive_frame` returns no frame
for the advertised packet. It additionally requires each frame's duration, precision, rate and
channel count to match, rejects extra output, and verifies exact total frames at clean EOF.
This demonstrates the four retained negative cases, not rejection of every corrupt ALAC file.
Ordinary FFmpeg CLI invocation, even with `-xerror -err_detect explode`, logged a decode problem
but exited zero with only 721 frames in this observation. Exit status alone is insufficient.

`native-packet-run-01/` was an invalid comparator: AudioFile reported zero variable-frame count
for the short last packet, and the probe incorrectly used the nominal 4,096 frames. The fixed
probe uses the independently known fixture packet lengths. A product reader must use validated
`stts` durations, never the decoder's reported output as its expected value. Initial compiler
failures and the invalid observation remain retained separately from the final comparison.

## Container work and remaining gates

The Android shared module now has `AlacFileMetadata`, with 24 real encoder metadata vectors.
Apple's own outer sample entry can contain 44.1 kHz/16-bit placeholders; the ALAC-specific
configuration supplies the actual rate and precision. The inspector cross-checks media time,
packet counts, sizes, chunk mappings and data bounds with bounded paged reads, without reading
compressed audio. 69 ALAC tests plus 126 existing WAVE/FLAC tests passed. This inspector does
not validate the compressed bitstream or authorize playback. Shared-module Android lint has
zero issues; the separate existing full-app lint failure was not rerun or waived.

The current inspector profile accepts one self-contained mono/stereo track, 16/20/24/32-bit
ALAC, bounded duration and metadata, 32/64-bit offsets and media headers. Edited timelines,
fragmented files, multiple tracks, external references and other channel layouts are explicitly
unsupported. The profile has not been advertised by either product. Ordinary edit-list/gapless
semantics and wider layout support still need implementation and independent fixtures.

Remaining: a qualified decoder shared with the product's held-reader and lifetime boundaries;
Apple-side container validation; platform native builds; negotiated ALAC capability; Android
and iOS senders, Mac/Windows receive state machines and consistent UI; authenticated original
file receipt and actual compatible-output playback. No speaker-format policy is relaxed.

Primary references: [ALAC configuration](https://github.com/macosforge/alac/blob/master/ALACMagicCookieDescription.txt),
[Apple sample-to-chunk table](https://developer.apple.com/documentation/quicktime-file-format/sample-to-chunk_atom),
[edit-list semantics](https://developer.apple.com/documentation/quicktime-file-format/playing_with_edit_lists),
and [FFmpeg ALAC decoder](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/alac.c).
These explain formats/APIs; the experiment receipts establish only the observed host behavior.
