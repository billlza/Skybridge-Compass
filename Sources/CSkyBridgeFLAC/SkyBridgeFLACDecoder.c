#include "SkyBridgeFLACDecoder.h"
#include <FLAC/stream_decoder.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define SBFLAC_MAX_FILE_BYTES (UINT64_C(16) * 1024 * 1024 * 1024)
#define SBFLAC_MAX_METADATA_BYTES (UINT64_C(64) * 1024 * 1024)
#define SBFLAC_MAX_READ_BYTES ((size_t)65536)
#define SBFLAC_MAX_ENCODED_FRAME_BYTES (UINT64_C(16) * 1024 * 1024)
#define SBFLAC_MAX_TOTAL_FRAMES ((UINT64_C(1) << 36) - 1)

struct SBFLACDecoder {
    FLAC__StreamDecoder *native;
    SBFLACSourceDescription source;
    uint64_t file_bytes;
    uint64_t maximum_frames;
    uint64_t read_offset;
    uint64_t decoded_frames;
    uint64_t last_frame_end;
    uint64_t operation_read_limit;
    uint32_t container_bytes;
    int metadata_seen;
    int metadata_checked;
    int prior_block_below_minimum;
    int md5_available;
    int md5_verified;
    int complete;
    int codec_error;
    SBFLACStatus failure;
    const SBFLACReadAccess *active;
    uint8_t *output;
    size_t output_capacity;
    uint32_t produced_frames;
    size_t produced_bytes;
};

static void fail(SBFLACDecoder *decoder, SBFLACStatus status)
{
    if (decoder->failure == SBFLAC_READY) decoder->failure = status;
}

static int cancelled(SBFLACDecoder *decoder)
{
    if (decoder->failure != SBFLAC_READY) return 1;
    if (!decoder->active || !decoder->active->read_at || !decoder->active->is_cancelled) {
        fail(decoder, SBFLAC_INVALID_ARGUMENT);
        return 1;
    }
    if (decoder->active->is_cancelled(decoder->active->context)) {
        fail(decoder, SBFLAC_CANCELLED);
        return 1;
    }
    return 0;
}

static FLAC__StreamDecoderReadStatus read_callback(const FLAC__StreamDecoder *native,
    FLAC__byte buffer[], size_t *bytes, void *opaque)
{
    (void)native;
    SBFLACDecoder *decoder = opaque;
    if (cancelled(decoder)) { *bytes = 0; return FLAC__STREAM_DECODER_READ_STATUS_ABORT; }
    if (decoder->read_offset == decoder->file_bytes) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }
    if (*bytes == 0 || decoder->read_offset >= decoder->operation_read_limit) {
        fail(decoder, decoder->metadata_checked ? SBFLAC_RESOURCE_LIMIT : SBFLAC_METADATA_MISMATCH);
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    size_t count = *bytes < SBFLAC_MAX_READ_BYTES ? *bytes : SBFLAC_MAX_READ_BYTES;
    uint64_t remaining = decoder->operation_read_limit - decoder->read_offset;
    if ((uint64_t)count > remaining) count = (size_t)remaining;
    size_t actual = 0;
    int error = decoder->active->read_at(decoder->active->context, decoder->read_offset, buffer, count, &actual);
    if (error || actual == 0 || actual > count) {
        fail(decoder, SBFLAC_SOURCE_ERROR);
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    if (cancelled(decoder)) { *bytes = 0; return FLAC__STREAM_DECODER_READ_STATUS_ABORT; }
    decoder->read_offset += actual; // Bounded by operation_read_limit <= file_bytes.
    *bytes = actual;
    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

static FLAC__StreamDecoderTellStatus tell_callback(const FLAC__StreamDecoder *native,
    FLAC__uint64 *offset, void *opaque)
{
    (void)native;
    SBFLACDecoder *decoder = opaque;
    *offset = decoder->read_offset;
    return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}

static void metadata_callback(const FLAC__StreamDecoder *native, const FLAC__StreamMetadata *metadata,
    void *opaque)
{
    (void)native;
    SBFLACDecoder *decoder = opaque;
    if (cancelled(decoder)) return;
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO || decoder->metadata_seen) {
        fail(decoder, SBFLAC_METADATA_MISMATCH);
        return;
    }
    decoder->metadata_seen = 1;
    const FLAC__StreamMetadata_StreamInfo *actual = &metadata->data.stream_info;
    const SBFLACSourceDescription *expected = &decoder->source;
    if (actual->sample_rate != expected->sample_rate || actual->channels != expected->channels ||
        actual->bits_per_sample != expected->valid_bits || actual->total_samples != expected->total_frames ||
        actual->min_blocksize != expected->minimum_block_frames || actual->max_blocksize != expected->maximum_block_frames ||
        actual->min_framesize != expected->minimum_frame_bytes || actual->max_framesize != expected->maximum_frame_bytes ||
        memcmp(actual->md5sum, expected->pcm_md5, 16) != 0) fail(decoder, SBFLAC_METADATA_MISMATCH);
}

static void error_callback(const FLAC__StreamDecoder *native, FLAC__StreamDecoderErrorStatus status,
    void *opaque)
{
    (void)native;
    SBFLACDecoder *decoder = opaque;
    if (decoder->codec_error < 0) decoder->codec_error = (int)status;
    // libFLAC can recover sync or pad a missing frame with silence. Strict mode must never admit
    // that recovery as source samples, even if a later write callback or EOS looks successful.
    fail(decoder, SBFLAC_CODEC_ERROR);
}

static FLAC__StreamDecoderWriteStatus write_callback(const FLAC__StreamDecoder *native,
    const FLAC__Frame *frame, const FLAC__int32 * const samples[], void *opaque)
{
    (void)native;
    SBFLACDecoder *decoder = opaque;
    if (cancelled(decoder)) return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    const SBFLACSourceDescription *source = &decoder->source;
    const FLAC__FrameHeader *header = &frame->header;
    if (!decoder->metadata_checked || decoder->produced_frames != 0 ||
        header->sample_rate != source->sample_rate || header->channels != source->channels ||
        header->bits_per_sample != source->valid_bits) {
        fail(decoder, SBFLAC_FORMAT_CHANGED);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    // libFLAC normalizes fixed-block frame numbers to absolute sample numbers before this callback.
    if (header->number_type != FLAC__FRAME_NUMBER_TYPE_SAMPLE_NUMBER ||
        header->number.sample_number != decoder->decoded_frames || decoder->prior_block_below_minimum) {
        fail(decoder, SBFLAC_FRAME_SEQUENCE_ERROR);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    if (header->blocksize == 0 || header->blocksize > source->maximum_block_frames) {
        fail(decoder, SBFLAC_FRAME_SIZE_ERROR);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    if (header->blocksize > source->total_frames - decoder->decoded_frames ||
        header->blocksize > decoder->maximum_frames - decoder->decoded_frames) {
        fail(decoder, SBFLAC_SAMPLE_COUNT_ERROR);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    size_t required = (size_t)header->blocksize * source->channels * decoder->container_bytes;
    if (!decoder->output || required > decoder->output_capacity) {
        fail(decoder, SBFLAC_RESOURCE_LIMIT);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    uint32_t shift = decoder->container_bytes * 8 - source->valid_bits;
    int64_t minimum = -(INT64_C(1) << (source->valid_bits - 1));
    int64_t maximum = (INT64_C(1) << (source->valid_bits - 1)) - 1;
    size_t position = 0;
    for (uint32_t i = 0; i < header->blocksize; i++) {
        for (uint32_t channel = 0; channel < source->channels; channel++) {
            int64_t sample = samples[channel][i];
            if (sample < minimum || sample > maximum) {
                fail(decoder, SBFLAC_SAMPLE_RANGE_ERROR);
                return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
            }
            // Unsigned shifting is defined for negative source integers after modulo conversion.
            uint32_t value = (uint32_t)sample << shift;
            if (decoder->container_bytes == 1) value ^= 0x80;
            for (uint32_t byte = 0; byte < decoder->container_bytes; byte++) {
                decoder->output[position++] = (uint8_t)(value >> (byte * 8));
            }
        }
    }
    if (cancelled(decoder)) return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    decoder->produced_frames = header->blocksize;
    decoder->produced_bytes = required;
    decoder->prior_block_below_minimum = header->blocksize < source->minimum_block_frames;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

SBFLACStatus sbflac_decoder_create(const SBFLACSourceDescription *source, uint64_t file_bytes,
    uint64_t maximum_frames, SBFLACDecoder **output)
{
    if (!output) return SBFLAC_INVALID_ARGUMENT;
    *output = NULL;
    if (!source || file_bytes < 43 || file_bytes > SBFLAC_MAX_FILE_BYTES ||
        source->sample_rate == 0 || source->sample_rate > 0xfffff ||
        source->channels < 1 || source->channels > 8 || source->valid_bits < 4 || source->valid_bits > 32 ||
        source->minimum_block_frames < 16 || source->maximum_block_frames < source->minimum_block_frames ||
        source->maximum_block_frames > 65535 || source->minimum_frame_bytes > 0xffffff || source->maximum_frame_bytes > 0xffffff ||
        (source->minimum_frame_bytes && source->maximum_frame_bytes && source->minimum_frame_bytes > source->maximum_frame_bytes) ||
        source->first_frame_byte_offset < 42 || source->first_frame_byte_offset > SBFLAC_MAX_METADATA_BYTES ||
        source->first_frame_byte_offset >= file_bytes || source->total_frames == 0 ||
        source->total_frames > SBFLAC_MAX_TOTAL_FRAMES || maximum_frames == 0 || maximum_frames > SBFLAC_MAX_TOTAL_FRAMES) {
        return SBFLAC_INVALID_ARGUMENT;
    }
    if (source->total_frames > maximum_frames) return SBFLAC_RESOURCE_LIMIT;
    SBFLACDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) return SBFLAC_ALLOCATION_FAILED;
    decoder->source = *source;
    decoder->file_bytes = file_bytes;
    decoder->maximum_frames = maximum_frames;
    decoder->container_bytes = (source->valid_bits + 7) / 8;
    decoder->codec_error = -1;
    decoder->failure = SBFLAC_READY;
    for (size_t i = 0; i < 16; i++) if (source->pcm_md5[i] != 0) decoder->md5_available = 1;
    decoder->native = FLAC__stream_decoder_new();
    if (!decoder->native) { free(decoder); return SBFLAC_ALLOCATION_FAILED; }
    // init_stream selects native FLAC. The chained-stream setter belongs to the optional Ogg
    // decoder and reports unsupported even for false when libFLAC was built without Ogg.
    if (!FLAC__stream_decoder_set_md5_checking(decoder->native, true) ||
        !FLAC__stream_decoder_set_metadata_ignore_all(decoder->native) ||
        !FLAC__stream_decoder_set_metadata_respond(decoder->native, FLAC__METADATA_TYPE_STREAMINFO) ||
        FLAC__stream_decoder_init_stream(decoder->native, read_callback, NULL, tell_callback, NULL, NULL,
            write_callback, metadata_callback, error_callback, decoder) != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        FLAC__stream_decoder_delete(decoder->native);
        free(decoder);
        return SBFLAC_CODEC_ERROR;
    }
    *output = decoder;
    return SBFLAC_READY;
}

static void fill_result(SBFLACDecoder *decoder, SBFLACResult *result, SBFLACStatus status)
{
    result->status = status;
    result->total_frames = decoder->decoded_frames;
    result->encoded_bytes_consumed = decoder->last_frame_end;
    result->md5_available = decoder->md5_available;
    result->md5_verified = decoder->md5_verified;
    result->codec_error = decoder->codec_error;
    if (status == SBFLAC_FRAME) {
        result->first_frame_index = decoder->decoded_frames - decoder->produced_frames;
        result->frame_count = decoder->produced_frames;
        result->byte_count = decoder->produced_bytes;
    }
}

SBFLACStatus sbflac_decoder_next(SBFLACDecoder *decoder, const SBFLACReadAccess *access,
    uint8_t *output, size_t output_capacity, SBFLACResult *result)
{
    if (!result) return SBFLAC_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));
    result->status = SBFLAC_INVALID_ARGUMENT;
    result->codec_error = -1;
    if (!decoder) return SBFLAC_INVALID_ARGUMENT;
    if (decoder->active || !access || !access->read_at || !access->is_cancelled || !output || output_capacity == 0) {
        fail(decoder, SBFLAC_INVALID_ARGUMENT);
        fill_result(decoder, result, decoder->failure);
        return decoder->failure;
    }
    decoder->active = access;
    decoder->output = output;
    decoder->output_capacity = output_capacity;
    decoder->produced_frames = 0;
    decoder->produced_bytes = 0;
    if (cancelled(decoder)) goto done;
    if (decoder->complete) goto done;
    if (!decoder->metadata_checked) {
        // Metadata parsing cannot consume frame data or skip beyond the inspected metadata end.
        decoder->operation_read_limit = decoder->source.first_frame_byte_offset;
        if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder->native)) fail(decoder, SBFLAC_CODEC_ERROR);
        if (cancelled(decoder)) goto done;
        FLAC__uint64 position = 0;
        if (!decoder->metadata_seen || !FLAC__stream_decoder_get_decode_position(decoder->native, &position) ||
            position != decoder->source.first_frame_byte_offset) {
            fail(decoder, SBFLAC_METADATA_MISMATCH);
            goto done;
        }
        decoder->metadata_checked = 1;
        decoder->last_frame_end = position;
    }
    uint64_t frame_budget = decoder->source.maximum_frame_bytes ? decoder->source.maximum_frame_bytes : SBFLAC_MAX_ENCODED_FRAME_BYTES;
    // The library can prefetch a bounded buffer past the current frame. Actual frame length is
    // checked from get_decode_position after the callback, before returning any valid PCM bytes.
    decoder->operation_read_limit = decoder->last_frame_end + frame_budget + SBFLAC_MAX_READ_BYTES;
    if (decoder->operation_read_limit > decoder->file_bytes) decoder->operation_read_limit = decoder->file_bytes;
    if (!FLAC__stream_decoder_process_single(decoder->native)) fail(decoder, SBFLAC_CODEC_ERROR);
    if (cancelled(decoder)) goto done;
    if (decoder->produced_frames) {
        FLAC__uint64 position = 0;
        if (!FLAC__stream_decoder_get_decode_position(decoder->native, &position) ||
            position <= decoder->last_frame_end || position > decoder->file_bytes) {
            fail(decoder, SBFLAC_INPUT_END_MISMATCH);
            goto done;
        }
        uint64_t frame_bytes = position - decoder->last_frame_end;
        if ((decoder->source.minimum_frame_bytes && frame_bytes < decoder->source.minimum_frame_bytes) || frame_bytes > frame_budget) {
            fail(decoder, SBFLAC_FRAME_SIZE_ERROR);
            goto done;
        }
        decoder->last_frame_end = position;
        decoder->decoded_frames += decoder->produced_frames;
    } else if (FLAC__stream_decoder_get_state(decoder->native) == FLAC__STREAM_DECODER_END_OF_STREAM) {
        if (decoder->decoded_frames != decoder->source.total_frames) { fail(decoder, SBFLAC_SAMPLE_COUNT_ERROR); goto done; }
        if (decoder->last_frame_end != decoder->file_bytes) { fail(decoder, SBFLAC_INPUT_END_MISMATCH); goto done; }
        if (!FLAC__stream_decoder_finish(decoder->native)) { fail(decoder, SBFLAC_MD5_MISMATCH); goto done; }
        decoder->md5_verified = decoder->md5_available;
        decoder->complete = 1;
    } else {
        fail(decoder, SBFLAC_CODEC_ERROR);
    }
done:
    decoder->active = NULL;
    decoder->output = NULL;
    decoder->output_capacity = 0;
    SBFLACStatus status = decoder->failure != SBFLAC_READY ? decoder->failure : decoder->complete ? SBFLAC_COMPLETE : SBFLAC_FRAME;
    fill_result(decoder, result, status);
    return status;
}

void sbflac_decoder_destroy(SBFLACDecoder *decoder)
{
    if (!decoder) return;
    FLAC__stream_decoder_delete(decoder->native);
    free(decoder);
}

const char *sbflac_linked_version(void) { return FLAC__VERSION_STRING; }
