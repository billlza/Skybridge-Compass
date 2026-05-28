pub(crate) fn is_unknown_suite_rejection_line(_line: &str, lower: &str) -> bool {
    lower.contains("suite_rejected_unknown")
        || lower.contains("wireid=0x0000")
        || lower.contains("unknown suite")
        || lower.contains("unknown-suite")
}

pub(crate) fn is_p2p_remote_fallback_failure_line(line: &str, lower: &str) -> bool {
    line.contains("降级 H.264")
        || lower.contains("fallbackproducer")
        || lower.contains("fallback producer")
        || lower.contains("fallback=true")
        || lower.contains("transport=fallback")
        || lower.contains("pipeline=stillimagefallback")
        || lower.contains("pipeline=samplebufferdisplaylayer")
        || lower.contains("renderpipeline=samplebufferdisplaylayer")
        || lower.contains("fallback path")
        || lower.contains("fallback activated")
        || lower.contains("fallback engaged")
        || lower.contains("compatibility fallback")
        || lower.contains("legacyfallback=true")
        || lower.contains("classic fallback")
        || lower.contains("classic fallback accepted")
        || lower.contains("h264 fallback")
        || (lower.contains("attemptedfallback=") && !lower.contains("attemptedfallback=none"))
        || (lower.contains("fallbackresult=")
            && !lower.contains("fallbackresult=none")
            && !lower.contains("fallbackresult=not-attempted"))
        || lower.contains("degraded to h.264")
        || lower.contains("render-main-path-failed")
        || lower.contains("strict-media-failed")
}

pub(crate) fn update_min_f64(slot: &mut Option<f64>, value: Option<f64>) {
    if let Some(value) = value
        && slot.is_none_or(|current| value < current)
    {
        *slot = Some(value);
    }
}

pub(crate) fn update_max_f64(slot: &mut Option<f64>, value: Option<f64>) {
    if let Some(value) = value
        && slot.is_none_or(|current| value > current)
    {
        *slot = Some(value);
    }
}

pub(crate) fn update_min_u64(slot: &mut Option<u64>, value: Option<u64>) {
    if let Some(value) = value
        && slot.is_none_or(|current| value < current)
    {
        *slot = Some(value);
    }
}

pub(crate) fn update_max_u64(slot: &mut Option<u64>, value: Option<u64>) {
    if let Some(value) = value
        && slot.is_none_or(|current| value > current)
    {
        *slot = Some(value);
    }
}

pub(crate) fn update_max_i64(slot: &mut Option<i64>, value: Option<i64>) {
    if let Some(value) = value
        && slot.is_none_or(|current| value > current)
    {
        *slot = Some(value);
    }
}

pub(crate) fn extract_text_value(text: &str, key: &str) -> Option<String> {
    let needle = format!("{key}=");
    let start = text.find(&needle)? + needle.len();
    let token = text[start..]
        .chars()
        .take_while(|value| !value.is_whitespace() && !matches!(value, ',' | '}' | ']' | ')' | '"'))
        .collect::<String>();
    let token = token.trim_matches(|value| value == '"' || value == '\'');
    if token.is_empty() {
        None
    } else {
        Some(token.to_owned())
    }
}

pub(super) fn extract_text_value_any(text: &str, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| extract_text_value(text, key))
}

pub(crate) fn extract_text_f64(text: &str, key: &str) -> Option<f64> {
    extract_text_value(text, key).and_then(|value| value.trim_end_matches('%').parse().ok())
}

pub(crate) fn extract_text_u64(text: &str, key: &str) -> Option<u64> {
    extract_text_value(text, key).and_then(|value| value.parse().ok())
}

pub(crate) fn extract_text_i64(text: &str, key: &str) -> Option<i64> {
    extract_text_value(text, key).and_then(|value| value.parse().ok())
}
