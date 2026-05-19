use crate::webrtc_media_parse::{find_webrtc_string, find_webrtc_u64};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct VideoDimensions {
    pub(crate) width: u32,
    pub(crate) height: u32,
}

pub(crate) const MAINSTREAM_WEBRTC_VIDEO_SIZES: &[VideoDimensions] = &[
    VideoDimensions {
        width: 1728,
        height: 1117,
    },
    VideoDimensions {
        width: 1920,
        height: 1200,
    },
    VideoDimensions {
        width: 2056,
        height: 1329,
    },
    VideoDimensions {
        width: 2560,
        height: 1600,
    },
    VideoDimensions {
        width: 2992,
        height: 1934,
    },
];

#[derive(Debug, Clone, Copy)]
pub(crate) struct ReceiverVideoDimensions {
    pub(crate) dimensions: VideoDimensions,
    pub(crate) explicit_visible: bool,
}

pub(crate) fn find_webrtc_native_video_receiver_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<ReceiverVideoDimensions> {
    if let Some(value) = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
    {
        return Some(ReceiverVideoDimensions {
            dimensions,
            explicit_visible: true,
        });
    }

    find_webrtc_video_dimensions(json, text).map(|dimensions| ReceiverVideoDimensions {
        dimensions,
        explicit_visible: false,
    })
}

pub(crate) fn find_webrtc_video_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<VideoDimensions> {
    if let (Some(width), Some(height)) = (
        find_webrtc_u64(json, text, "width"),
        find_webrtc_u64(json, text, "height"),
    ) {
        return video_dimensions_from_u64(width, height);
    }

    for key in [
        "visibleSize",
        "visibleFrame",
        "size",
        "frame",
        "lastFrame",
        "encodeSize",
        "target",
    ] {
        if let Some(value) = find_webrtc_string(json, text, key)
            && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
        {
            return Some(dimensions);
        }
    }
    None
}

pub(crate) fn parse_webrtc_video_dimensions(value: &str) -> Option<VideoDimensions> {
    let size = value.split_once('@').map_or(value, |(size, _)| size).trim();
    let (width, height) = size.split_once('x').or_else(|| size.split_once('X'))?;
    let width = width
        .trim()
        .trim_matches(|value: char| !value.is_ascii_digit())
        .parse::<u64>()
        .ok()?;
    let height = height
        .trim()
        .trim_matches(|value: char| !value.is_ascii_digit())
        .parse::<u64>()
        .ok()?;
    video_dimensions_from_u64(width, height)
}

fn video_dimensions_from_u64(width: u64, height: u64) -> Option<VideoDimensions> {
    if width == 0 || height == 0 || width > u32::MAX as u64 || height > u32::MAX as u64 {
        return None;
    }
    Some(VideoDimensions {
        width: width as u32,
        height: height as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_dimension_strings_and_structured_values() {
        assert_eq!(
            parse_webrtc_video_dimensions("2056x1329@60"),
            Some(VideoDimensions {
                width: 2056,
                height: 1329,
            })
        );
        assert_eq!(
            parse_webrtc_video_dimensions("(1920X1200)"),
            Some(VideoDimensions {
                width: 1920,
                height: 1200,
            })
        );
        assert_eq!(parse_webrtc_video_dimensions("0x1200"), None);
        assert_eq!(parse_webrtc_video_dimensions("not-a-size"), None);

        let value = json!({"nested": {"width": 2992, "height": 1934}});
        assert_eq!(
            find_webrtc_video_dimensions(Some(&value), ""),
            Some(VideoDimensions {
                width: 2992,
                height: 1934,
            })
        );
    }

    #[test]
    fn receiver_dimensions_prefer_explicit_visible_size() {
        let value = json!({
            "width": 100,
            "height": 100,
            "visibleSize": "2056x1329",
        });
        let dimensions = find_webrtc_native_video_receiver_dimensions(Some(&value), "")
            .expect("receiver dimensions");
        assert_eq!(
            dimensions.dimensions,
            VideoDimensions {
                width: 2056,
                height: 1329,
            }
        );
        assert!(dimensions.explicit_visible);
    }
}
