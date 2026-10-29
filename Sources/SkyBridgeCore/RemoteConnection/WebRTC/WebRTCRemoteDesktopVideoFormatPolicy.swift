import Foundation
import VideoToolbox

enum WebRTCRemoteDesktopVideoFormatPolicy {
    static func effectiveRemoteVideoFormats(
        advertisedFormats: Set<String>,
        streamConfiguration config: RemoteDesktopStreamConfiguration?
    ) -> Set<String> {
        if config?.preferredCodec?.lowercased() == "jpeg" {
            return ["jpeg"]
        }

        var formats = Set(BonjourInteropContract.normalizedRemoteVideoFormats(advertisedFormats))
        if let config {
            formats.formUnion(BonjourInteropContract.normalizedRemoteVideoFormats(config.supportedVideoFormats))
            if let preferred = config.preferredCodec?.lowercased(),
               preferred == "h264" || preferred == "hevc" || preferred == "jpeg" {
                formats.insert(preferred)
            }
        }
        return formats
    }

    static func effectiveNativeCaptureVideoFormats(
        localSupportedFormats: [String],
        streamConfiguration config: RemoteDesktopStreamConfiguration?
    ) -> Set<String> {
        var formats = Set(BonjourInteropContract.normalizedRemoteVideoFormats(localSupportedFormats))
        if let config {
            for format in BonjourInteropContract.normalizedRemoteVideoFormats(config.supportedVideoFormats) where format != "jpeg" {
                formats.insert(format)
            }
            if let preferred = config.preferredCodec?.lowercased(),
               preferred == "h264" || preferred == "hevc" {
                formats.insert(preferred)
            }
        }
        return formats
    }

    static func supportedRemoteVideoFormats(
        hevcHardwareDecodeSupported: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    ) -> [String] {
        var formats = ["jpeg", "h264"]
        if hevcHardwareDecodeSupported {
            formats.insert("hevc", at: 0)
        }
        var seen: Set<String> = []
        return formats.filter { seen.insert($0).inserted }
    }
}
