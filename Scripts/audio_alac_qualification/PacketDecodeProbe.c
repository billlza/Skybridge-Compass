/* Isolated libavcodec qualification using already-installed development libraries.
 * No product dependency or capability is added. The product must supply committed reads,
 * authorize each effect, and package a separately reviewed, source-locked native build.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/samplefmt.h>

static int number(const char *text, int64_t maximum, int64_t *value) {
    char *end = NULL;
    errno = 0;
    int64_t result = strtoll(text, &end, 10);
    if (errno || end == text || *end || result <= 0 || result > maximum) return 0;
    *value = result;
    return 1;
}

static void diagnostic(const char *step, int code) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    if (av_strerror(code, message, sizeof(message)) < 0) {
        fprintf(stderr, "%s: status=%d\n", step, code);
    } else fprintf(stderr, "%s: %s (%d)\n", step, message, code);
}

int main(int argc, char **argv) {
    int64_t rate, channels, bits, expected_frames;
    if (argc != 7 || !number(argv[3], 384000, &rate) || !number(argv[4], 2, &channels) ||
        !number(argv[5], 32, &bits) || !number(argv[6], 384000LL * 14400, &expected_frames) ||
        (bits != 16 && bits != 20 && bits != 24 && bits != 32)) {
        fprintf(stderr, "invalid qualification arguments\n");
        return 2;
    }
    AVFormatContext *format = NULL;
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    FILE *output = NULL;
    AVDictionary *options = NULL;
    int result = 1;
    int status;
    int stream_index = -1;
    int64_t frames = 0;
    int64_t packets = 0;
    unsigned width = (unsigned)(bits + 7) / 8;
    av_log_set_level(AV_LOG_WARNING);
    if ((status = av_dict_set(&options, "protocol_whitelist", "file", 0)) < 0) {
        diagnostic("protocol whitelist", status); goto cleanup;
    }
    status = avformat_open_input(&format, argv[1], av_find_input_format("mov"), &options);
    av_dict_free(&options);
    if (status < 0) { diagnostic("open", status); goto cleanup; }
    /* Do not call find_stream_info: it may decode and discard invalid leading packets. */
    for (unsigned index = 0; index < format->nb_streams; index++) {
        if (format->streams[index]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            if (stream_index >= 0) { fprintf(stderr, "ambiguous audio track\n"); goto cleanup; }
            stream_index = (int)index;
        }
    }
    if (stream_index < 0) { fprintf(stderr, "missing audio track\n"); goto cleanup; }
    AVStream *stream = format->streams[stream_index];
    AVCodecParameters *parameters = stream->codecpar;
    if (parameters->codec_id != AV_CODEC_ID_ALAC || parameters->sample_rate != rate ||
        parameters->ch_layout.nb_channels != channels || stream->time_base.num != 1 || stream->time_base.den != rate) {
        fprintf(stderr, "source declaration differs\n"); goto cleanup;
    }
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_ALAC);
    if (!codec || !(decoder = avcodec_alloc_context3(codec))) { fprintf(stderr, "decoder unavailable\n"); goto cleanup; }
    if ((status = avcodec_parameters_to_context(decoder, parameters)) < 0) { diagnostic("parameters", status); goto cleanup; }
    decoder->err_recognition = AV_EF_EXPLODE | AV_EF_CAREFUL;
    decoder->thread_count = 1;
    if ((status = avcodec_open2(decoder, codec, NULL)) < 0) { diagnostic("decoder open", status); goto cleanup; }
    if (decoder->bits_per_raw_sample != bits || decoder->sample_rate != rate || decoder->ch_layout.nb_channels != channels) {
        fprintf(stderr, "decoded precision or layout differs\n"); goto cleanup;
    }
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!packet || !frame) { fprintf(stderr, "allocation failed\n"); goto cleanup; }
    output = fopen(argv[2], "wbx");
    if (!output) { fprintf(stderr, "output open failed: %s\n", strerror(errno)); goto cleanup; }
    while ((status = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index != stream_index) { av_packet_unref(packet); continue; }
        if (packet->size <= 0 || packet->size > 2097120 || packet->duration <= 0 || packet->duration > 65536) {
            fprintf(stderr, "packet bounds differ\n"); goto cleanup;
        }
        const int64_t packet_frames = packet->duration;
        if ((status = avcodec_send_packet(decoder, packet)) < 0) { diagnostic("submit packet", status); goto cleanup; }
        av_packet_unref(packet);
        status = avcodec_receive_frame(decoder, frame);
        if (status < 0) { diagnostic("packet produced no valid frame", status); goto cleanup; }
        if (frame->nb_samples != packet_frames || frame->sample_rate != rate || frame->ch_layout.nb_channels != channels ||
            frame->format != (bits == 16 ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S32P) ||
            frame->nb_samples > expected_frames - frames) {
            fprintf(stderr, "packet PCM declaration differs\n"); goto cleanup;
        }
        for (int sample = 0; sample < frame->nb_samples; sample++) {
            for (int channel = 0; channel < channels; channel++) {
                if (!frame->extended_data[channel]) { fprintf(stderr, "missing channel plane\n"); goto cleanup; }
                uint32_t value;
                if (bits == 16) {
                    uint16_t s16;
                    memcpy(&s16, frame->extended_data[channel] + (size_t)sample * 2, sizeof(s16));
                    value = (uint32_t)s16 << 16;
                } else memcpy(&value, frame->extended_data[channel] + (size_t)sample * 4, sizeof(value));
                unsigned unused = 32U - (unsigned)bits;
                if (unused && (value & ((UINT32_C(1) << unused) - 1)) != 0) {
                    fprintf(stderr, "undeclared low precision bits\n"); goto cleanup;
                }
                uint8_t packed[4];
                value >>= 32U - width * 8;
                for (unsigned byte = 0; byte < width; byte++) packed[byte] = (uint8_t)(value >> (8 * byte));
                if (fwrite(packed, 1, width, output) != width) { fprintf(stderr, "output write failed\n"); goto cleanup; }
            }
        }
        frames += frame->nb_samples;
        packets++;
        av_frame_unref(frame);
        status = avcodec_receive_frame(decoder, frame);
        if (status != AVERROR(EAGAIN)) { diagnostic("unexpected extra packet output", status); goto cleanup; }
    }
    if (status != AVERROR_EOF) { diagnostic("input ended with error", status); goto cleanup; }
    if ((status = avcodec_send_packet(decoder, NULL)) < 0) { diagnostic("finish input", status); goto cleanup; }
    status = avcodec_receive_frame(decoder, frame);
    if (status != AVERROR_EOF || frames != expected_frames) { fprintf(stderr, "stream completion differs\n"); goto cleanup; }
    result = 0;
cleanup:
    av_dict_free(&options);
    if (output && fclose(output) != 0) { fprintf(stderr, "output close failed\n"); result = 1; }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    if (result == 0) printf("{\"frames\":%" PRId64 ",\"packets\":%" PRId64 ",\"validBits\":%" PRId64
                            ",\"rate\":%" PRId64 ",\"channels\":%" PRId64 ",\"decoderVersion\":%u}\n",
                            frames, packets, bits, rate, channels, avcodec_version());
    return result;
}
