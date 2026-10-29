use std::path::Path;

pub(crate) fn summarize_webrtc_evidence_line(
    source: &Path,
    line_number: usize,
    line: &str,
) -> String {
    let file_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("log");
    let redacted = redact_sensitive_log_fragment(line);
    let summary = redacted.chars().take(180).collect::<String>();
    format!("{file_name}:{line_number} {summary}")
}

fn redact_sensitive_log_fragment(line: &str) -> String {
    if let Ok(mut value) = serde_json::from_str::<serde_json::Value>(line) {
        redact_sensitive_json_value(&mut value);
        return serde_json::to_string(&value).unwrap_or_else(|_| "<redacted-json>".to_owned());
    }

    let mut redacted = Vec::new();
    let mut redact_next = false;
    for part in line.split_whitespace() {
        if redact_next {
            redacted.push("<redacted>".to_owned());
            redact_next = part.eq_ignore_ascii_case("bearer");
            continue;
        }
        let (part, next_is_sensitive) = redact_sensitive_log_part(part);
        redacted.push(part);
        redact_next = next_is_sensitive;
    }
    redacted.join(" ")
}

fn redact_sensitive_json_value(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(object) => {
            for (key, value) in object.iter_mut() {
                if is_sensitive_log_key(key) {
                    *value = serde_json::Value::String("<redacted>".to_owned());
                } else {
                    redact_sensitive_json_value(value);
                }
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                redact_sensitive_json_value(value);
            }
        }
        _ => {}
    }
}

fn redact_sensitive_log_part(part: &str) -> (String, bool) {
    if let Some((key, value)) = part.split_once('=')
        && is_sensitive_log_key(key)
    {
        let redact_next = value.is_empty() || value.eq_ignore_ascii_case("bearer");
        return (format!("{key}=<redacted>"), redact_next);
    }
    if let Some((key, value)) = part.split_once(':')
        && is_sensitive_log_key(key)
        && !key.contains('/')
    {
        let redact_next = value.is_empty() || value.eq_ignore_ascii_case("bearer");
        return (format!("{key}:<redacted>"), redact_next);
    }
    (part.to_owned(), false)
}

fn is_sensitive_log_key(key: &str) -> bool {
    let normalized = key
        .trim_matches(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != '-')
        .to_ascii_lowercase();
    normalized.contains("token")
        || normalized.contains("authorization")
        || normalized.contains("jwt")
        || normalized.contains("secret")
        || normalized.contains("password")
        || normalized.contains("credential")
        || normalized.contains("cookie")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarizes_and_redacts_json_and_plain_log_fragments() {
        let json_summary = summarize_webrtc_evidence_line(
            Path::new("/tmp/webrtc.jsonl"),
            7,
            r#"{"event":"x","token":"secret","nested":{"authorization":"Bearer abc"}}"#,
        );
        assert!(json_summary.contains("webrtc.jsonl:7"));
        assert!(json_summary.contains("<redacted>"));
        assert!(!json_summary.contains("secret"));
        assert!(!json_summary.contains("Bearer abc"));

        let plain_summary = summarize_webrtc_evidence_line(
            Path::new("/tmp/webrtc.log"),
            9,
            "event token=secret Authorization: Bearer abc ok=1",
        );
        assert!(plain_summary.contains("token=<redacted>"));
        assert!(plain_summary.contains("Authorization:<redacted> <redacted>"));
        assert!(!plain_summary.contains("secret"));
    }
}
