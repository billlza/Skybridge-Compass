#ifndef SKYBRIDGE_ALAC_DECODER_H
#define SKYBRIDGE_ALAC_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SBALACDecoder SBALACDecoder;
typedef enum {
    SBALAC_READY = 0, SBALAC_FRAME = 1, SBALAC_COMPLETE = 2,
    SBALAC_INVALID_ARGUMENT = 100, SBALAC_ALLOCATION_FAILED, SBALAC_UNQUALIFIED_PROVIDER,
    SBALAC_INVALID_SOURCE, SBALAC_CANCELLED, SBALAC_CODEC_ERROR, SBALAC_MISSING_FRAME,
    SBALAC_FORMAT_CHANGED, SBALAC_FRAME_COUNT_MISMATCH, SBALAC_EXTRA_OUTPUT,
    SBALAC_SAMPLE_RANGE_ERROR, SBALAC_SEQUENCE_ERROR
} SBALACStatus;

/* The original, opaque 24-byte big-endian ALACSpecificConfig from the same validated container.
 * Finite mono/stereo profile: 16/20/24/32 valid bits, <=65536 frames/packet, <=4194304 packets,
 * <=4 hours. Container indexing, hashes, authorization and file lifetime belong to the caller.
 */
typedef struct {
    uint8_t configuration[24];
    uint64_t total_frames;
    uint64_t packet_count;
} SBALACSourceDescription;

/* Borrowed synchronously for this call only; nonzero cancels. Must not reenter/destroy the owner.
 * A language-level owner must serialize calls/destruction and defer reentrant close requests.
 */
typedef int (*SBALACIsCancelled)(void *context);
typedef struct { void *context; SBALACIsCancelled is_cancelled; } SBALACControl;

typedef struct {
    SBALACStatus status;
    int32_t codec_error;
    uint64_t packet_index;
    uint64_t first_frame_index;
    uint32_t frame_count;
    size_t byte_count;
    uint64_t decoded_frames;
    uint64_t decoded_packets;
} SBALACResult;

/* On failure the decoder remains NULL and result preserves the native initialization error. */
SBALACStatus sbalac_decoder_create(const SBALACSourceDescription *source, SBALACDecoder **decoder, SBALACResult *result);

/* One indexed packet, obtained through the caller's same commitment-verified reader. Expected
 * frames come from the validated container time table, never the decoder's returned frame count.
 * No resampling, gain, concealment or format fallback. Output is interleaved little endian,
 * high-aligned valid bits in the smallest 16/24/32-bit integer container. Input/output storage is
 * borrowed only during this call. Every error is terminal; discard every output byte on failure.
 */
SBALACStatus sbalac_decoder_decode(SBALACDecoder *decoder, const SBALACControl *control,
    uint64_t packet_index, uint64_t first_frame_index, const uint8_t *packet, size_t packet_bytes,
    uint32_t expected_frames, uint8_t *output, size_t output_capacity, SBALACResult *result);

/* Requires all declared packets/frames and a clean codec flush with no extra output. */
SBALACStatus sbalac_decoder_finish(SBALACDecoder *decoder, const SBALACControl *control, SBALACResult *result);
void sbalac_decoder_destroy(SBALACDecoder *decoder);
const char *sbalac_linked_version(void);
unsigned sbalac_provider_contract_version(void);

#ifdef __cplusplus
}
#endif
#endif
