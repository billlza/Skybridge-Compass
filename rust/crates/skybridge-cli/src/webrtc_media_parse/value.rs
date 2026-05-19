use crate::performance_evidence::{extract_text_f64, extract_text_u64, extract_text_value};

pub(crate) fn find_webrtc_f64(
    json: Option<&serde_json::Value>,
    text: &str,
    key: &str,
) -> Option<f64> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_f64))
        .or_else(|| extract_text_f64(text, key))
}

pub(crate) fn find_webrtc_f64_any(
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
) -> Option<f64> {
    keys.iter().find_map(|key| find_webrtc_f64(json, text, key))
}

pub(crate) fn find_webrtc_string_any(
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .find_map(|key| find_webrtc_string(json, text, key))
}

pub(crate) fn find_webrtc_u64(
    json: Option<&serde_json::Value>,
    text: &str,
    key: &str,
) -> Option<u64> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_u64))
        .or_else(|| extract_text_u64(text, key))
}

pub(crate) fn find_webrtc_string(
    json: Option<&serde_json::Value>,
    text: &str,
    key: &str,
) -> Option<String> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_string))
        .or_else(|| extract_text_value(text, key))
}

pub(crate) fn find_json_value<'a>(
    value: &'a serde_json::Value,
    key: &str,
) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(value) = map.get(key) {
                return Some(value);
            }
            map.values().find_map(|child| find_json_value(child, key))
        }
        serde_json::Value::Array(items) => {
            items.iter().find_map(|child| find_json_value(child, key))
        }
        _ => None,
    }
}

pub(crate) fn json_value_to_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(value) => Some(value.clone()),
        serde_json::Value::Number(value) => Some(value.to_string()),
        serde_json::Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

fn json_value_to_f64(value: &serde_json::Value) -> Option<f64> {
    match value {
        serde_json::Value::Number(value) => value.as_f64(),
        serde_json::Value::String(value) => value.parse::<f64>().ok(),
        _ => None,
    }
}

fn json_value_to_u64(value: &serde_json::Value) -> Option<u64> {
    match value {
        serde_json::Value::Number(value) => value.as_u64(),
        serde_json::Value::String(value) => value.parse::<u64>().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn find_helpers_cover_json_recursion_and_text_fallback() {
        let value = json!({
            "outer": [
                {"inner": {"fps": "59.9", "frames": "42", "ok": true}}
            ]
        });
        assert_eq!(find_webrtc_f64(Some(&value), "", "fps"), Some(59.9));
        assert_eq!(find_webrtc_u64(Some(&value), "", "frames"), Some(42));
        assert_eq!(
            find_webrtc_string(Some(&value), "", "ok"),
            Some("true".to_owned())
        );
        assert_eq!(find_webrtc_f64(None, "fps=60.0", "fps"), Some(60.0));
        assert_eq!(find_webrtc_u64(None, "frames=12", "frames"), Some(12));
        assert_eq!(
            find_webrtc_string(None, "session=SESSION1", "session"),
            Some("SESSION1".to_owned())
        );
        assert_eq!(
            find_webrtc_f64_any(None, "videoFPS=60.0", &["fps", "videoFPS"]),
            Some(60.0)
        );
        assert_eq!(
            find_webrtc_string_any(None, "session_id=S1", &["session", "session_id"]),
            Some("S1".to_owned())
        );
    }
}
