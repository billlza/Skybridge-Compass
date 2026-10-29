use super::super::evidence::{CounterObservation, WebRtcMediaEvidence};

pub(super) fn webrtc_counter_has_continuity(
    window: &CounterObservation,
    total: Option<&CounterObservation>,
) -> bool {
    describe_webrtc_counter_continuity("counter", window, total).is_none()
}

pub(super) fn webrtc_rendered_frames_have_continuity(evidence: &WebRtcMediaEvidence) -> bool {
    describe_webrtc_rendered_frames_continuity(evidence).is_none()
}

pub(super) fn describe_webrtc_counter_continuity(
    label: &str,
    window: &CounterObservation,
    total: Option<&CounterObservation>,
) -> Option<String> {
    if let Some(total) = total
        && let (Some(first), Some(latest)) = (
            total.first_positive.as_ref(),
            total.latest_positive.as_ref(),
        )
        && latest.sequence > first.sequence
        && latest.value > first.value
    {
        return None;
    }

    if window.positive_count >= 2 && window.zero_after_positive.is_none() {
        return None;
    }

    if let Some(total) = total
        && let Some(decrease) = total.decrease_after_positive.as_ref()
    {
        return Some(format!(
            "{label} total decreased after positive traffic; evidence {}",
            decrease.evidence
        ));
    }

    if let Some(zero) = window.zero_after_positive.as_ref() {
        return Some(format!(
            "{label} returned to zero after positive traffic; evidence {}",
            zero.evidence
        ));
    }

    let latest = window
        .latest
        .as_ref()
        .map(|metric| metric.value.to_string())
        .unwrap_or_else(|| "missing".to_owned());
    let total_hint = total
        .and_then(|total| total.latest.as_ref())
        .map(|metric| format!("; latest total {}", metric.value))
        .unwrap_or_default();
    Some(format!(
        "{label} needs at least two positive rolling samples or an increasing total; latest {latest}; positiveSamples={}{}",
        window.positive_count, total_hint
    ))
}

pub(super) fn describe_webrtc_rendered_frames_continuity(
    evidence: &WebRtcMediaEvidence,
) -> Option<String> {
    let window = &evidence.audio_rendered_frames;
    if window.positive_count >= 2 {
        return None;
    }

    if window.seen_positive
        && webrtc_counter_has_continuity(
            &evidence.audio_rx_played,
            Some(&evidence.audio_rx_played_total),
        )
    {
        return None;
    }

    let latest = window
        .latest
        .as_ref()
        .map(|metric| metric.value.to_string())
        .unwrap_or_else(|| "missing".to_owned());
    Some(format!(
        "renderedFrames needs positive render samples while audio playback counters advance; latest {latest}; positiveSamples={}",
        window.positive_count
    ))
}

#[cfg(test)]
mod tests {
    use super::super::super::evidence::observe_webrtc_counter;
    use super::*;
    use serde_json::json;

    #[test]
    fn webrtc_counter_continuity_allows_duplicate_source_total_replay_when_rolling_is_active() {
        let mut rolling = CounterObservation::default();
        let mut total = CounterObservation::default();
        for (sequence, value) in [(1, 230), (2, 225), (3, 240)] {
            let json = json!({ "audioRxRecv": value });
            observe_webrtc_counter(
                &mut rolling,
                Some(&json),
                "",
                "audioRxRecv",
                sequence,
                &format!("rolling:{sequence}"),
            );
        }
        for (sequence, value) in [(1, 1_000), (2, 1_240), (3, 230)] {
            let json = json!({ "recvTotal": value });
            observe_webrtc_counter(
                &mut total,
                Some(&json),
                "",
                "recvTotal",
                sequence,
                &format!("total:{sequence}"),
            );
        }

        assert!(total.decrease_after_positive.is_some());
        assert!(
            describe_webrtc_counter_continuity("audioRxRecv", &rolling, Some(&total)).is_none()
        );
    }
}
