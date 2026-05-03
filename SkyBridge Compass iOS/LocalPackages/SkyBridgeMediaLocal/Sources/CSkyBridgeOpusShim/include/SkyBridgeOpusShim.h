#ifndef SKYBRIDGE_OPUS_SHIM_H
#define SKYBRIDGE_OPUS_SHIM_H

#include <opus/opus.h>

#ifdef __cplusplus
extern "C" {
#endif

int skybridge_opus_encoder_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate);
int skybridge_opus_encoder_set_complexity(OpusEncoder *encoder, opus_int32 complexity);
int skybridge_opus_encoder_set_inband_fec(OpusEncoder *encoder, opus_int32 enabled);
int skybridge_opus_encoder_set_packet_loss_perc(OpusEncoder *encoder, opus_int32 percent);
int skybridge_opus_encoder_set_dtx(OpusEncoder *encoder, opus_int32 enabled);
int skybridge_opus_encoder_set_signal(OpusEncoder *encoder, opus_int32 signal);

#ifdef __cplusplus
}
#endif

#endif
