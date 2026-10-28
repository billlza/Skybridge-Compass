#ifndef SKYBRIDGE_FLAC_DECODER_H
#define SKYBRIDGE_FLAC_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SBFLACDecoder SBFLACDecoder;

typedef enum {
    SBFLAC_READY = 0,
    SBFLAC_FRAME = 1,
    SBFLAC_COMPLETE = 2,
    SBFLAC_INVALID_ARGUMENT = 100,
    SBFLAC_ALLOCATION_FAILED,
    SBFLAC_SOURCE_ERROR,
    SBFLAC_CANCELLED,
    SBFLAC_METADATA_MISMATCH,
    SBFLAC_CODEC_ERROR,
    SBFLAC_FORMAT_CHANGED,
    SBFLAC_FRAME_SEQUENCE_ERROR,
    SBFLAC_FRAME_SIZE_ERROR,
    SBFLAC_RESOURCE_LIMIT,
    SBFLAC_SAMPLE_RANGE_ERROR,
    SBFLAC_SAMPLE_COUNT_ERROR,
    SBFLAC_INPUT_END_MISMATCH,
    SBFLAC_MD5_MISMATCH
} SBFLACStatus;

// Declarations from the same immutable/commitment-verified native FLAC file. Zero frame byte sizes
// and all-zero MD5 retain their format-defined "unknown" meanings. This finite-file decoder requires
// a positive declared sample count; metadata inspection may separately describe unknown-length files.
typedef struct {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t valid_bits;
    uint32_t minimum_block_frames;
    uint32_t maximum_block_frames;
    uint32_t minimum_frame_bytes;
    uint32_t maximum_frame_bytes;
    uint64_t total_frames;
    uint64_t first_frame_byte_offset;
    uint8_t pcm_md5[16];
} SBFLACSourceDescription;

// Synchronous, borrowed for one sbflac_decoder_next call only. Return 0 for a successful read,
// nonzero for a real source/authorization error. Short positive reads are accepted. Zero before
// the declared end, or more than capacity, fails. The callback must never write beyond capacity.
typedef int (*SBFLACReadAt)(void *context, uint64_t offset, uint8_t *buffer, size_t capacity,
                            size_t *bytes_read);
typedef int (*SBFLACIsCancelled)(void *context);
typedef struct {
    void *context;
    SBFLACReadAt read_at;
    SBFLACIsCancelled is_cancelled;
} SBFLACReadAccess;

typedef struct {
    SBFLACStatus status;
    uint64_t first_frame_index;
    uint32_t frame_count;
    size_t byte_count;
    uint64_t total_frames;
    uint64_t encoded_bytes_consumed;
    int md5_available;
    int md5_verified;
    // -1 means no libFLAC error callback. 0 is a real LOST_SYNC error, not "none".
    int codec_error;
} SBFLACResult;

// All operations require one serialized owner. Callbacks are synchronous; this API starts no
// threads, opens no path/descriptor and stores no caller read access after next returns. The owner
// must not destroy/reenter the decoder from a callback or access it concurrently. The outer wrapper
// retains the file, exact-channel/account authority and output resources independently.
SBFLACStatus sbflac_decoder_create(const SBFLACSourceDescription *source, uint64_t file_bytes,
                                  uint64_t maximum_frames, SBFLACDecoder **decoder);

// Produces at most one whole frame into the caller's buffer. On failure discard every output byte.
// Required capacity is maximum_block_frames * channels * ceil(valid_bits / 8), at most 2,097,120.
// Sample integers are interleaved, little-endian and high aligned; 8-bit containers use offset binary.
// SBFLAC_COMPLETE requires exact declared frame count, exact encoded EOF, no codec error callback,
// and successful available STREAMINFO MD5 verification. It does not mean playback or authorization.
SBFLACStatus sbflac_decoder_next(SBFLACDecoder *decoder, const SBFLACReadAccess *access,
                                uint8_t *output, size_t output_capacity, SBFLACResult *result);

// Frees native decoder state only. Early destruction is cancellation, never completed decoding.
void sbflac_decoder_destroy(SBFLACDecoder *decoder);
const char *sbflac_linked_version(void);

#ifdef __cplusplus
}
#endif
#endif
