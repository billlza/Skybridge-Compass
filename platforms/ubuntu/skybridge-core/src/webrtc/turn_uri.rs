/// Returns the best TURN URI supported by the current Rust WebRTC runtime.
///
/// `webrtc-ice` 0.17 only gathers relay candidates for `turn:` URLs over UDP.
/// Secure `turns:` and `turn:...?transport=tcp` endpoints are currently parsed
/// but not wired into relay gathering, so selecting them causes live ICE
/// failures instead of a usable fallback.
pub fn preferred_turn_uri_for_webrtc_rs(server_uris: &[String]) -> Option<String> {
    server_uris
        .iter()
        .map(|uri| uri.trim())
        .find(|uri| is_supported_turn_udp_uri(uri))
        .map(ToOwned::to_owned)
}

pub fn preferred_turn_uri_with_override(
    server_uris: &[String],
    override_url: &str,
) -> Option<String> {
    let override_url = override_url.trim();
    if !override_url.is_empty() {
        return Some(override_url.to_string());
    }
    preferred_turn_uri_for_webrtc_rs(server_uris)
}

fn is_supported_turn_udp_uri(raw: &str) -> bool {
    if raw.is_empty() {
        return false;
    }

    let lower = raw.to_ascii_lowercase();
    if !lower.starts_with("turn:") {
        return false;
    }

    !lower.contains("transport=tcp")
}

#[cfg(test)]
mod tests {
    use super::{preferred_turn_uri_for_webrtc_rs, preferred_turn_uri_with_override};

    #[test]
    fn prefers_udp_turn_over_turns_and_tcp() {
        let uris = vec![
            "turns:54.92.79.99:5349?transport=tcp".to_string(),
            "turn:54.92.79.99:3478?transport=tcp".to_string(),
            "turn:54.92.79.99:3478?transport=udp".to_string(),
        ];

        let selected = preferred_turn_uri_for_webrtc_rs(&uris);

        assert_eq!(
            selected.as_deref(),
            Some("turn:54.92.79.99:3478?transport=udp")
        );
    }

    #[test]
    fn accepts_plain_turn_without_explicit_transport() {
        let uris = vec!["turn:54.92.79.99:3478".to_string()];

        let selected = preferred_turn_uri_for_webrtc_rs(&uris);

        assert_eq!(selected.as_deref(), Some("turn:54.92.79.99:3478"));
    }

    #[test]
    fn rejects_only_unsupported_turn_variants() {
        let uris = vec![
            "turns:54.92.79.99:5349?transport=tcp".to_string(),
            "turn:54.92.79.99:3478?transport=tcp".to_string(),
        ];

        let selected = preferred_turn_uri_for_webrtc_rs(&uris);

        assert!(selected.is_none());
    }

    #[test]
    fn explicit_override_wins() {
        let uris = vec!["turn:54.92.79.99:3478?transport=udp".to_string()];

        let selected = preferred_turn_uri_with_override(
            &uris,
            "turns:override.example.com:5349?transport=tcp",
        );

        assert_eq!(
            selected.as_deref(),
            Some("turns:override.example.com:5349?transport=tcp")
        );
    }
}
