#if os(macOS)
import SkyBridgeAudioFile

// Preserve the existing Mac call sites while iOS uses the same decoder implementation.
typealias AudioFlacDecodeError = SkyBridgeAudioFile.AudioFlacDecodeError
typealias AudioFlacDecodeReceipt = SkyBridgeAudioFile.AudioFlacDecodeReceipt
typealias AudioFlacDecodeStep = SkyBridgeAudioFile.AudioFlacDecodeStep
typealias AudioFlacPCMDecoder = SkyBridgeAudioFile.AudioFlacPCMDecoder
#endif
