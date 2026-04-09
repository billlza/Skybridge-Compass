use skybridge_core::remote::{
    AutoDecoder, UltraStreamCodec, UltraStreamDecodedFrame, UltraStreamDecoder, UltraStreamFrame,
};
use skybridge_core::webrtc::ScreenDataWire;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DecodedRemoteFrame {
    pub(crate) width: u16,
    pub(crate) height: u16,
    pub(crate) bgra: Vec<u8>,
}

pub(crate) struct RemoteJsonVideoState {
    decoder: Option<AutoDecoder>,
}

impl RemoteJsonVideoState {
    pub(crate) fn new() -> Self {
        Self {
            decoder: AutoDecoder::new().ok(),
        }
    }

    pub(crate) fn decode_screen_data(
        &mut self,
        screen: &ScreenDataWire,
    ) -> Result<Option<DecodedRemoteFrame>, String> {
        decode_screen_data_with_decoder(screen, self.decoder.as_mut())
    }
}

fn normalized_format(screen: &ScreenDataWire) -> String {
    let raw = screen.format.as_deref().unwrap_or("").trim().to_lowercase();
    if raw.is_empty() && looks_like_jpeg(&screen.image_data) {
        "jpeg".to_string()
    } else {
        raw
    }
}

fn screen_dimensions(screen: &ScreenDataWire) -> (u16, u16) {
    (
        (screen.width.max(1).min(i32::from(u16::MAX))) as u16,
        (screen.height.max(1).min(i32::from(u16::MAX))) as u16,
    )
}

fn looks_like_jpeg(bytes: &[u8]) -> bool {
    bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
}

fn decode_jpeg_to_bgra(bytes: &[u8]) -> Result<(u16, u16, Vec<u8>), String> {
    use jpeg_decoder::{Decoder, PixelFormat};
    use std::io::Cursor;

    let mut decoder = Decoder::new(Cursor::new(bytes));
    let pixels = decoder.decode().map_err(|e| e.to_string())?;
    let info = decoder
        .info()
        .ok_or_else(|| "missing jpeg info".to_string())?;

    let width = info.width;
    let height = info.height;

    let mut bgra = Vec::with_capacity(width as usize * height as usize * 4);
    match info.pixel_format {
        PixelFormat::RGB24 => {
            for chunk in pixels.chunks_exact(3) {
                let r = chunk[0];
                let g = chunk[1];
                let b = chunk[2];
                bgra.push(b);
                bgra.push(g);
                bgra.push(r);
                bgra.push(0xFF);
            }
        }
        PixelFormat::L8 => {
            for &l in &pixels {
                bgra.push(l);
                bgra.push(l);
                bgra.push(l);
                bgra.push(0xFF);
            }
        }
        other => return Err(format!("unsupported jpeg pixel format: {:?}", other)),
    }

    Ok((width, height, bgra))
}

fn decode_screen_data_with_decoder<D: UltraStreamDecoder>(
    screen: &ScreenDataWire,
    decoder: Option<&mut D>,
) -> Result<Option<DecodedRemoteFrame>, String> {
    if screen.image_data.is_empty() {
        return Ok(None);
    }

    let (width, height) = screen_dimensions(screen);
    let format = normalized_format(screen);

    match format.as_str() {
        "jpeg" | "image/jpeg" => {
            let (decoded_width, decoded_height, bgra) = decode_jpeg_to_bgra(&screen.image_data)?;
            Ok(Some(DecodedRemoteFrame {
                width: decoded_width,
                height: decoded_height,
                bgra,
            }))
        }
        "bgra" => {
            let expected = width as usize * height as usize * 4;
            if screen.image_data.len() != expected {
                return Err(format!(
                    "BGRA payload length mismatch: expected {} bytes, got {}",
                    expected,
                    screen.image_data.len()
                ));
            }
            Ok(Some(DecodedRemoteFrame {
                width,
                height,
                bgra: screen.image_data.clone(),
            }))
        }
        "h264" | "hevc" => {
            let codec = if format == "h264" {
                UltraStreamCodec::H264
            } else {
                UltraStreamCodec::Hevc
            };
            let Some(decoder) = decoder else {
                return Err(format!("{} decoder unavailable", format));
            };
            let frame = UltraStreamFrame {
                codec,
                frame_id: 0,
                timestamp_ms: 0,
                width,
                height,
                data: screen.image_data.clone(),
            };
            match decoder.decode(&frame).map_err(|err| err.to_string())? {
                UltraStreamDecodedFrame::Bgra {
                    width,
                    height,
                    data,
                } => Ok(Some(DecodedRemoteFrame {
                    width,
                    height,
                    bgra: data,
                })),
                UltraStreamDecodedFrame::Encoded(_) => Ok(None),
            }
        }
        _ => {
            if looks_like_jpeg(&screen.image_data) {
                let (decoded_width, decoded_height, bgra) =
                    decode_jpeg_to_bgra(&screen.image_data)?;
                Ok(Some(DecodedRemoteFrame {
                    width: decoded_width,
                    height: decoded_height,
                    bgra,
                }))
            } else {
                Ok(None)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeDecoder;

    impl UltraStreamDecoder for FakeDecoder {
        fn decode(
            &mut self,
            frame: &UltraStreamFrame,
        ) -> Result<UltraStreamDecodedFrame, skybridge_core::remote::UltraStreamError> {
            Ok(UltraStreamDecodedFrame::Bgra {
                width: frame.width,
                height: frame.height,
                data: vec![0x7F; frame.width as usize * frame.height as usize * 4],
            })
        }
    }

    #[test]
    fn bgra_payload_passes_through() {
        let screen = ScreenDataWire {
            width: 2,
            height: 1,
            image_data: vec![1, 2, 3, 4, 5, 6, 7, 8],
            timestamp: 0.0,
            format: Some("bgra".to_string()),
        };

        let frame = decode_screen_data_with_decoder::<FakeDecoder>(&screen, None)
            .expect("decode ok")
            .expect("frame");
        assert_eq!(frame.width, 2);
        assert_eq!(frame.height, 1);
        assert_eq!(frame.bgra, screen.image_data);
    }

    #[test]
    fn h264_payload_routes_through_decoder() {
        let screen = ScreenDataWire {
            width: 4,
            height: 2,
            image_data: vec![0, 0, 0, 1, 0x65],
            timestamp: 0.0,
            format: Some("h264".to_string()),
        };

        let mut decoder = FakeDecoder;
        let frame = decode_screen_data_with_decoder(&screen, Some(&mut decoder))
            .expect("decode ok")
            .expect("frame");
        assert_eq!(frame.width, 4);
        assert_eq!(frame.height, 2);
        assert_eq!(frame.bgra.len(), 4 * 2 * 4);
    }

    #[test]
    fn h264_requires_decoder() {
        let screen = ScreenDataWire {
            width: 4,
            height: 2,
            image_data: vec![0, 0, 0, 1, 0x65],
            timestamp: 0.0,
            format: Some("h264".to_string()),
        };

        let err = decode_screen_data_with_decoder::<FakeDecoder>(&screen, None)
            .expect_err("decoder should be required");
        assert!(err.contains("decoder unavailable"));
    }

    #[test]
    fn unknown_non_jpeg_payload_is_ignored() {
        let screen = ScreenDataWire {
            width: 1,
            height: 1,
            image_data: vec![1, 2, 3, 4],
            timestamp: 0.0,
            format: Some("opaque".to_string()),
        };

        assert!(
            decode_screen_data_with_decoder::<FakeDecoder>(&screen, None)
                .expect("decode ok")
                .is_none()
        );
    }
}
