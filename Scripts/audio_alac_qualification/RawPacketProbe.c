/* Isolated observation of one source-locked provider packet. Exit 0 requires an actual frame;
 * stderr retains codec diagnostics. This deliberately does not implement the product contract. */
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>

static uint8_t *read_file(const char *path, size_t maximum, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    uint8_t *data = malloc(maximum + 1);
    if (!data) { fclose(file); return NULL; }
    *length = fread(data, 1, maximum + 1, file);
    int bad = ferror(file) || *length == 0 || *length > maximum;
    if (fclose(file) != 0) bad = 1;
    if (bad) { free(data); return NULL; }
    return data;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    size_t config_size = 0, packet_size = 0;
    uint8_t *config = read_file(argv[1], 24, &config_size);
    uint8_t *bytes = read_file(argv[2], 2097120, &packet_size);
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_ALAC);
    AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : NULL;
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    int result = 2;
    if (!config || config_size != 24 || !bytes || !context || !frame || !packet) goto cleanup;
    context->extradata = av_mallocz(36 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!context->extradata) goto cleanup;
    context->extradata_size = 36;
    context->extradata[3] = 36;
    memcpy(context->extradata + 4, "alac", 4);
    memcpy(context->extradata + 12, config, 24);
    context->err_recognition = AV_EF_EXPLODE | AV_EF_CAREFUL;
    context->thread_count = 1;
    int opened = avcodec_open2(context, codec, NULL);
    int submitted = INT_MIN, received = INT_MIN;
    if (opened >= 0) {
        if (av_new_packet(packet, (int)packet_size) < 0) goto cleanup;
        memcpy(packet->data, bytes, packet_size);
        submitted = avcodec_send_packet(context, packet);
        if (submitted >= 0) received = avcodec_receive_frame(context, frame);
    }
    int accepted = received >= 0 && frame->nb_samples > 0;
    int all_zero = accepted;
    if (accepted) {
        int width = av_get_bytes_per_sample(frame->format);
        if (width <= 0 || width > 4 || frame->nb_samples > 65536 ||
            frame->ch_layout.nb_channels < 1 || frame->ch_layout.nb_channels > 2 ||
            !av_sample_fmt_is_planar(frame->format)) goto cleanup;
        for (int channel = 0; channel < frame->ch_layout.nb_channels; channel++) {
            if (!frame->extended_data[channel]) goto cleanup;
            for (int byte = 0; byte < frame->nb_samples * width; byte++)
                if (frame->extended_data[channel][byte] != 0) all_zero = 0;
        }
    }
    printf("{\"version\":\"%s\",\"opened\":%d,\"submitted\":%d,\"received\":%d,"
           "\"frameAccepted\":%s,\"frames\":%d,\"allZero\":%s,\"errorFlags\":%d}\n",
           av_version_info(), opened, submitted, received, accepted ? "true" : "false",
           frame->nb_samples, all_zero ? "true" : "false", frame->decode_error_flags);
    result = accepted ? 0 : 1;
cleanup:
    free(config); free(bytes);
    av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&context);
    return result;
}
