#include "SkyBridgeALACDecoder.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>

/* Exported only by the source-locked strict-error provider. A stock host library cannot satisfy
 * this dependency merely by having a compatible FFmpeg ABI/version number. */
extern unsigned avcodec_alac_strict_errors_version(void);

struct SBALACDecoder {
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    uint32_t sample_rate, channels, valid_bits, frame_length, maximum_packet_bytes;
    uint32_t frame_bytes;
    uint64_t expected_frames, expected_packets, frames, packets;
    SBALACStatus failure;
    int32_t codec_error;
    int complete;
};

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static int matches_layout(const AVChannelLayout *layout, uint32_t channels) {
    return layout->nb_channels == (int)channels && layout->order == AV_CHANNEL_ORDER_NATIVE &&
        layout->u.mask == (channels == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO);
}

static void release_codec(SBALACDecoder *d) {
    av_frame_free(&d->frame);
    av_packet_free(&d->packet);
    avcodec_free_context(&d->codec);
}

static void report(SBALACDecoder *d, SBALACStatus status, SBALACResult *r) {
    if (!r) return;
    memset(r, 0, sizeof(*r));
    r->status = status;
    if (d) {
        r->codec_error = d->codec_error;
        r->decoded_frames = d->frames;
        r->decoded_packets = d->packets;
        r->packet_index = d->packets;
        r->first_frame_index = d->frames;
    }
}

static SBALACStatus fail(SBALACDecoder *d, SBALACStatus status, int error, SBALACResult *r) {
    if (d && d->failure == SBALAC_READY) {
        d->failure = status;
        d->codec_error = error;
        release_codec(d);
    }
    if (d) status = d->failure;
    report(d, status, r);
    return status;
}

unsigned sbalac_provider_contract_version(void) { return avcodec_alac_strict_errors_version(); }
const char *sbalac_linked_version(void) { return av_version_info(); }

void sbalac_decoder_destroy(SBALACDecoder *d) {
    if (!d) return;
    release_codec(d);
    free(d);
}

static SBALACStatus creation_failed(SBALACDecoder *d, SBALACStatus status, int error, SBALACResult *result) {
    report(d, status, result);
    if (result) result->codec_error = error;
    sbalac_decoder_destroy(d);
    return status;
}

SBALACStatus sbalac_decoder_create(const SBALACSourceDescription *source, SBALACDecoder **out, SBALACResult *result) {
    if (!out) return creation_failed(NULL, SBALAC_INVALID_ARGUMENT, 0, result);
    *out = NULL;
    if (!source || !result) return creation_failed(NULL, SBALAC_INVALID_ARGUMENT, 0, result);
    if (sbalac_provider_contract_version() != 1) return creation_failed(NULL, SBALAC_UNQUALIFIED_PROVIDER, 0, result);
    const uint8_t *c = source->configuration;
    uint32_t length = be32(c), bits = c[5], channels = c[9], maximum = be32(c + 12), rate = be32(c + 20);
    if (c[4] != 0 || length == 0 || length > 65536 || maximum > 2097120 || rate == 0 || rate > INT_MAX ||
        (bits != 16 && bits != 20 && bits != 24 && bits != 32) || channels == 0 || channels > 2 ||
        (uint64_t)rate * channels * ((bits + 7) / 8) > UINT32_MAX ||
        source->packet_count == 0 || source->packet_count > 4194304 || source->total_frames < source->packet_count ||
        source->total_frames > source->packet_count * length || source->total_frames > (uint64_t)rate * 14400) {
        return creation_failed(NULL, SBALAC_INVALID_SOURCE, 0, result);
    }
    SBALACDecoder *d = calloc(1, sizeof(*d));
    if (!d) return creation_failed(NULL, SBALAC_ALLOCATION_FAILED, AVERROR(ENOMEM), result);
    d->sample_rate = rate; d->channels = channels; d->valid_bits = bits; d->frame_length = length;
    d->maximum_packet_bytes = maximum;
    d->frame_bytes = channels * ((bits + 7) / 8);
    d->expected_frames = source->total_frames; d->expected_packets = source->packet_count;
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_ALAC);
    if (!codec) return creation_failed(d, SBALAC_UNQUALIFIED_PROVIDER, 0, result);
    if (!(d->codec = avcodec_alloc_context3(codec)) || !(d->packet = av_packet_alloc()) || !(d->frame = av_frame_alloc())) {
        return creation_failed(d, SBALAC_ALLOCATION_FAILED, AVERROR(ENOMEM), result);
    }
    d->codec->extradata = av_mallocz(36 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!d->codec->extradata) return creation_failed(d, SBALAC_ALLOCATION_FAILED, AVERROR(ENOMEM), result);
    d->codec->extradata_size = 36;
    d->codec->extradata[3] = 36;
    memcpy(d->codec->extradata + 4, "alac", 4);
    memcpy(d->codec->extradata + 12, c, 24);
    d->codec->sample_rate = (int)rate;
    av_channel_layout_default(&d->codec->ch_layout, (int)channels);
    d->codec->err_recognition = AV_EF_EXPLODE | AV_EF_CAREFUL;
    d->codec->thread_count = 1;
    d->codec->max_samples = (int64_t)length * channels;
    const int opened = avcodec_open2(d->codec, codec, NULL);
    if (opened < 0) {
        return creation_failed(d, opened == AVERROR(ENOMEM) ? SBALAC_ALLOCATION_FAILED : SBALAC_CODEC_ERROR, opened, result);
    }
    if (d->codec->sample_rate != (int)rate ||
        !matches_layout(&d->codec->ch_layout, channels) || d->codec->bits_per_raw_sample != (int)bits) {
        return creation_failed(d, SBALAC_FORMAT_CHANGED, 0, result);
    }
    *out = d;
    report(d, SBALAC_READY, result);
    return SBALAC_READY;
}

SBALACStatus sbalac_decoder_decode(SBALACDecoder *d, const SBALACControl *control,
    uint64_t packet_index, uint64_t first_frame_index, const uint8_t *packet, size_t packet_bytes,
    uint32_t expected_frames, uint8_t *output, size_t capacity, SBALACResult *r) {
    if (!d) { report(NULL, SBALAC_INVALID_ARGUMENT, r); return SBALAC_INVALID_ARGUMENT; }
    if (d->failure != SBALAC_READY) return fail(d, d->failure, d->codec_error, r);
    if (!r || !control || !control->is_cancelled || !packet || !output || packet_bytes == 0 || packet_bytes > 2097120 ||
        (d->maximum_packet_bytes && packet_bytes > d->maximum_packet_bytes) ||
        expected_frames == 0 || expected_frames > d->frame_length || capacity < (size_t)expected_frames * d->frame_bytes) {
        return fail(d, SBALAC_INVALID_ARGUMENT, 0, r);
    }
    if (d->complete || packet_index != d->packets || first_frame_index != d->frames || d->packets >= d->expected_packets ||
        expected_frames > d->expected_frames - d->frames) return fail(d, SBALAC_SEQUENCE_ERROR, 0, r);
    if (control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
    int status = av_new_packet(d->packet, (int)packet_bytes);
    if (status < 0) return fail(d, SBALAC_ALLOCATION_FAILED, status, r);
    memcpy(d->packet->data, packet, packet_bytes);
    d->packet->duration = expected_frames;
    status = avcodec_send_packet(d->codec, d->packet);
    av_packet_unref(d->packet);
    if (status < 0) return fail(d, SBALAC_CODEC_ERROR, status, r);
    status = avcodec_receive_frame(d->codec, d->frame);
    if (status < 0) return fail(d, status == AVERROR(EAGAIN) ? SBALAC_MISSING_FRAME : SBALAC_CODEC_ERROR, status, r);
    if ((d->frame->flags & AV_FRAME_FLAG_CORRUPT) != 0 || d->frame->decode_error_flags != 0) return fail(d, SBALAC_CODEC_ERROR, AVERROR_INVALIDDATA, r);
    if (d->frame->sample_rate != (int)d->sample_rate || !matches_layout(&d->frame->ch_layout, d->channels) ||
        d->frame->format != (d->valid_bits == 16 ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S32P)) return fail(d, SBALAC_FORMAT_CHANGED, 0, r);
    if (d->frame->nb_samples != (int)expected_frames) return fail(d, SBALAC_FRAME_COUNT_MISMATCH, 0, r);
    if (!d->frame->extended_data || d->frame->linesize[0] < (int)expected_frames * (d->valid_bits == 16 ? 2 : 4)) {
        return fail(d, SBALAC_FORMAT_CHANGED, 0, r);
    }
    if (control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
    const unsigned width = (d->valid_bits + 7) / 8;
    const unsigned unused = 32 - d->valid_bits;
    const uint32_t low_mask = unused ? (UINT32_C(1) << unused) - 1 : 0;
    size_t written = 0;
    for (uint32_t sample = 0; sample < expected_frames; sample++) {
        if ((sample & 1023U) == 0 && control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
        for (uint32_t channel = 0; channel < d->channels; channel++) {
            if (!d->frame->extended_data[channel]) return fail(d, SBALAC_FORMAT_CHANGED, 0, r);
            uint32_t value;
            if (d->valid_bits == 16) {
                uint16_t sample16;
                memcpy(&sample16, d->frame->extended_data[channel] + (size_t)sample * 2, sizeof(sample16));
                value = (uint32_t)sample16 << 16;
            } else memcpy(&value, d->frame->extended_data[channel] + (size_t)sample * 4, sizeof(value));
            if (value & low_mask) return fail(d, SBALAC_SAMPLE_RANGE_ERROR, 0, r);
            value >>= 32 - width * 8;
            for (unsigned byte = 0; byte < width; byte++) output[written++] = (uint8_t)(value >> (8 * byte));
        }
    }
    av_frame_unref(d->frame);
    status = avcodec_receive_frame(d->codec, d->frame);
    if (status != AVERROR(EAGAIN)) return fail(d, SBALAC_EXTRA_OUTPUT, status, r);
    if (control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
    d->frames += expected_frames;
    d->packets++;
    report(d, SBALAC_FRAME, r);
    r->packet_index = packet_index;
    r->first_frame_index = first_frame_index;
    r->frame_count = expected_frames;
    r->byte_count = written;
    return SBALAC_FRAME;
}

SBALACStatus sbalac_decoder_finish(SBALACDecoder *d, const SBALACControl *control, SBALACResult *r) {
    if (!d) { report(NULL, SBALAC_INVALID_ARGUMENT, r); return SBALAC_INVALID_ARGUMENT; }
    if (d->failure != SBALAC_READY) return fail(d, d->failure, d->codec_error, r);
    if (!r || !control || !control->is_cancelled) return fail(d, SBALAC_INVALID_ARGUMENT, 0, r);
    if (control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
    if (d->frames != d->expected_frames || d->packets != d->expected_packets) return fail(d, SBALAC_FRAME_COUNT_MISMATCH, 0, r);
    if (!d->complete) {
        int status = avcodec_send_packet(d->codec, NULL);
        if (status < 0) return fail(d, SBALAC_CODEC_ERROR, status, r);
        status = avcodec_receive_frame(d->codec, d->frame);
        if (status != AVERROR_EOF) return fail(d, SBALAC_EXTRA_OUTPUT, status, r);
        if (control->is_cancelled(control->context)) return fail(d, SBALAC_CANCELLED, 0, r);
        d->complete = 1;
        release_codec(d);
    }
    report(d, SBALAC_COMPLETE, r);
    return SBALAC_COMPLETE;
}
