use time::{OffsetDateTime, UtcOffset};

use super::value::find_json_value;

pub(crate) fn parse_webrtc_diagnostic_timestamp(
    text: &str,
    json: Option<&serde_json::Value>,
) -> Option<OffsetDateTime> {
    if let Some(json) = json {
        for key in ["timestamp", "time", "ts", "date", "created_at", "createdAt"] {
            if let Some(value) = find_json_value(json, key).and_then(parse_json_timestamp_value) {
                return Some(value);
            }
        }
    }
    let timestamp = text.strip_prefix('[')?.split_once(']')?.0;
    OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339).ok()
}

pub(crate) fn parse_webrtc_local_console_timestamp(
    text: &str,
    anchor: OffsetDateTime,
) -> Option<OffsetDateTime> {
    parse_webrtc_local_console_timestamp_with_offset(text, anchor, current_log_utc_offset())
}

fn current_log_utc_offset() -> UtcOffset {
    UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC)
}

pub(crate) fn parse_webrtc_local_console_timestamp_with_offset(
    text: &str,
    anchor: OffsetDateTime,
    offset: UtcOffset,
) -> Option<OffsetDateTime> {
    let timestamp = text.strip_prefix('[')?.split_once(']')?.0;
    if timestamp.contains('T') || timestamp.contains('-') {
        return None;
    }
    let mut parts = timestamp.split(':');
    let hour = parts.next()?.parse::<u8>().ok()?;
    let minute = parts.next()?.parse::<u8>().ok()?;
    let seconds_and_fraction = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    let (second_raw, fraction_raw) = seconds_and_fraction
        .split_once('.')
        .map_or((seconds_and_fraction, ""), |(second, fraction)| {
            (second, fraction)
        });
    let second = second_raw.parse::<u8>().ok()?;
    if !fraction_raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let mut micro_digits = fraction_raw.to_owned();
    micro_digits.truncate(6);
    while micro_digits.len() < 6 {
        micro_digits.push('0');
    }
    let microsecond = if micro_digits.is_empty() {
        0
    } else {
        micro_digits.parse::<u32>().ok()?
    };
    let local_time = time::Time::from_hms_micro(hour, minute, second, microsecond).ok()?;
    let anchor_local = anchor.to_offset(offset);
    let mut candidate = anchor_local
        .date()
        .with_time(local_time)
        .assume_offset(offset);
    if candidate - anchor > time::Duration::hours(12) {
        candidate -= time::Duration::days(1);
    } else if anchor - candidate > time::Duration::hours(12) {
        candidate += time::Duration::days(1);
    }
    Some(candidate)
}

fn parse_json_timestamp_value(value: &serde_json::Value) -> Option<OffsetDateTime> {
    if let Some(value) = value.as_str() {
        return OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok();
    }
    let value = value.as_i64()?;
    let seconds = if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    };
    OffsetDateTime::from_unix_timestamp(seconds).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_timestamps_cover_json_bracketed_and_numeric_values() -> anyhow::Result<()> {
        let text = "[2026-05-16T01:00:01Z] native-video-tx session=SESSION";
        assert_eq!(
            parse_webrtc_diagnostic_timestamp(text, None),
            Some(OffsetDateTime::parse(
                "2026-05-16T01:00:01Z",
                &time::format_description::well_known::Rfc3339,
            )?)
        );
        assert_eq!(
            parse_webrtc_diagnostic_timestamp(
                "",
                Some(&json!({"nested": {"createdAt": "2026-05-16T01:00:02Z"}})),
            ),
            Some(OffsetDateTime::parse(
                "2026-05-16T01:00:02Z",
                &time::format_description::well_known::Rfc3339,
            )?)
        );
        assert_eq!(
            parse_webrtc_diagnostic_timestamp(
                "",
                Some(&json!({"timestamp": 1_700_000_000_000_i64})),
            ),
            OffsetDateTime::from_unix_timestamp(1_700_000_000).ok()
        );
        Ok(())
    }

    #[test]
    fn parse_local_console_timestamp_anchors_across_day_boundaries() -> anyhow::Result<()> {
        let anchor = OffsetDateTime::parse(
            "2026-05-16T00:00:01Z",
            &time::format_description::well_known::Rfc3339,
        )?;
        let parsed = parse_webrtc_local_console_timestamp_with_offset(
            "[23:59:59.250] event",
            anchor,
            UtcOffset::UTC,
        )
        .expect("local timestamp");
        assert_eq!(parsed.date(), (anchor - time::Duration::days(1)).date());
        assert_eq!(parsed.time().second(), 59);
        assert!(
            parse_webrtc_local_console_timestamp_with_offset(
                "[2026-05-16T00:00:00Z] event",
                anchor,
                UtcOffset::UTC,
            )
            .is_none()
        );
        Ok(())
    }
}
