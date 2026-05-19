use super::super::types::{CounterObservation, ObservedMetric};
use crate::webrtc_media_parse::{find_webrtc_f64_any, find_webrtc_string_any, find_webrtc_u64};

pub(in crate::webrtc_media_doctor) fn observe_webrtc_counter(
    observation: &mut CounterObservation,
    json: Option<&serde_json::Value>,
    text: &str,
    key: &str,
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_u64(json, text, key) else {
        return;
    };
    let observed = ObservedMetric {
        value,
        sequence,
        evidence: summary.to_owned(),
    };
    if let Some(previous) = observation.latest.as_ref()
        && observation.seen_positive
        && value < previous.value
    {
        update_latest_metric(&mut observation.decrease_after_positive, observed.clone());
    }
    if value > 0 {
        if observation.first_positive.is_none() {
            observation.first_positive = Some(observed.clone());
        }
        observation.seen_positive = true;
        observation.positive_count = observation.positive_count.saturating_add(1);
        update_latest_metric(&mut observation.latest_positive, observed.clone());
    } else if observation.seen_positive {
        update_latest_metric(&mut observation.zero_after_positive, observed.clone());
    }
    update_latest_metric(&mut observation.latest, observed.clone());
    update_lowest_u64(&mut observation.lowest, observed);
}

pub(in crate::webrtc_media_doctor) fn observe_webrtc_latest_f64_any(
    observation: &mut Option<ObservedMetric<f64>>,
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_f64_any(json, text, keys) else {
        return;
    };
    update_latest_metric(
        observation,
        ObservedMetric {
            value,
            sequence,
            evidence: summary.to_owned(),
        },
    );
}

pub(in crate::webrtc_media_doctor) fn observe_webrtc_latest_string_any(
    observation: &mut Option<ObservedMetric<String>>,
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_string_any(json, text, keys) else {
        return;
    };
    let value = value.trim();
    if value.is_empty() || value == "-" {
        return;
    }
    update_latest_metric(
        observation,
        ObservedMetric {
            value: value.to_owned(),
            sequence,
            evidence: summary.to_owned(),
        },
    );
}

pub(in crate::webrtc_media_doctor) fn update_latest_metric<T>(
    slot: &mut Option<ObservedMetric<T>>,
    observed: ObservedMetric<T>,
) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.sequence >= current.sequence)
    {
        *slot = Some(observed);
    }
}

pub(in crate::webrtc_media_doctor) fn update_lowest_f64(
    slot: &mut Option<ObservedMetric<f64>>,
    observed: ObservedMetric<f64>,
) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value < current.value)
    {
        *slot = Some(observed);
    }
}

pub(in crate::webrtc_media_doctor) fn update_highest_f64(
    slot: &mut Option<ObservedMetric<f64>>,
    observed: ObservedMetric<f64>,
) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value > current.value)
    {
        *slot = Some(observed);
    }
}

fn update_lowest_u64(slot: &mut Option<ObservedMetric<u64>>, observed: ObservedMetric<u64>) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value < current.value)
    {
        *slot = Some(observed);
    }
}
