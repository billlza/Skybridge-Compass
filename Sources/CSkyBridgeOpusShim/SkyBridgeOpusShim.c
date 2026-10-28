#include "SkyBridgeOpusShim.h"

int skybridge_opus_encoder_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int skybridge_opus_encoder_set_vbr(OpusEncoder *encoder, opus_int32 enabled) {
    if (encoder == 0) {
        return OPUS_BAD_ARG;
    }
    return opus_encoder_ctl(encoder, OPUS_SET_VBR(enabled));
}

int skybridge_opus_encoder_set_vbr_constraint(OpusEncoder *encoder, opus_int32 enabled) {
    if (encoder == 0) {
        return OPUS_BAD_ARG;
    }
    return opus_encoder_ctl(encoder, OPUS_SET_VBR_CONSTRAINT(enabled));
}

int skybridge_opus_encoder_set_complexity(OpusEncoder *encoder, opus_int32 complexity) {
    return opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int skybridge_opus_encoder_set_inband_fec(OpusEncoder *encoder, opus_int32 enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(enabled));
}

int skybridge_opus_encoder_set_packet_loss_perc(OpusEncoder *encoder, opus_int32 percent) {
    return opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(percent));
}

int skybridge_opus_encoder_set_dtx(OpusEncoder *encoder, opus_int32 enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_DTX(enabled));
}

int skybridge_opus_encoder_set_signal(OpusEncoder *encoder, opus_int32 signal) {
    return opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(signal));
}

int skybridge_opus_encoder_get_lookahead(OpusEncoder *encoder, opus_int32 *samples_per_channel) {
    if (encoder == 0 || samples_per_channel == 0) {
        return OPUS_BAD_ARG;
    }
    return opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(samples_per_channel));
}
