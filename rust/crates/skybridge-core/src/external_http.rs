use anyhow::Result;
use reqwest::{Response, StatusCode};
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use thiserror::Error;

pub(crate) const MAX_EXTERNAL_ERROR_BODY_BYTES: usize = 4 * 1024;
pub(crate) const MAX_EXTERNAL_JSON_BODY_BYTES: usize = 1024 * 1024;

#[derive(Debug, Error)]
pub(crate) enum ExternalHttpError {
    #[error("{service} {operation} transport failed ({failure_class})")]
    Transport {
        service: &'static str,
        operation: &'static str,
        failure_class: &'static str,
    },
    #[error(
        "{service} {operation} was rejected (HTTP {status}, code={error_code}, body_truncated={body_truncated})"
    )]
    Rejected {
        service: &'static str,
        operation: &'static str,
        status: StatusCode,
        error_code: &'static str,
        body_truncated: bool,
    },
    #[error("{service} {operation} response body could not be read")]
    BodyRead {
        service: &'static str,
        operation: &'static str,
    },
    #[error("{service} {operation} response exceeded the {limit_bytes}-byte limit")]
    BodyTooLarge {
        service: &'static str,
        operation: &'static str,
        limit_bytes: usize,
    },
    #[error("{service} {operation} returned invalid JSON")]
    InvalidJson {
        service: &'static str,
        operation: &'static str,
    },
}

pub(crate) struct InspectedJsonResponse {
    pub status: StatusCode,
    pub body: Value,
}

pub(crate) fn transport_error(
    service: &'static str,
    operation: &'static str,
    error: &reqwest::Error,
) -> anyhow::Error {
    let failure_class = if error.is_timeout() {
        "timeout"
    } else if error.is_connect() {
        "connect"
    } else if error.is_redirect() {
        "redirect"
    } else if error.is_request() {
        "request"
    } else if error.is_body() {
        "body"
    } else if error.is_decode() {
        "decode"
    } else {
        "transport"
    };
    anyhow::Error::new(ExternalHttpError::Transport {
        service,
        operation,
        failure_class,
    })
}

pub(crate) async fn decode_json_response<T: DeserializeOwned>(
    response: Response,
    service: &'static str,
    operation: &'static str,
) -> Result<T> {
    let status = response.status();
    if !status.is_success() {
        let (body, body_truncated) =
            read_bounded_body(response, MAX_EXTERNAL_ERROR_BODY_BYTES, service, operation).await?;
        return Err(anyhow::Error::new(ExternalHttpError::Rejected {
            service,
            operation,
            status,
            error_code: extract_allowlisted_error_code(&body),
            body_truncated,
        }));
    }

    let (body, body_truncated) =
        read_bounded_body(response, MAX_EXTERNAL_JSON_BODY_BYTES, service, operation).await?;
    if body_truncated {
        return Err(anyhow::Error::new(ExternalHttpError::BodyTooLarge {
            service,
            operation,
            limit_bytes: MAX_EXTERNAL_JSON_BODY_BYTES,
        }));
    }
    serde_json::from_slice(&body)
        .map_err(|_| anyhow::Error::new(ExternalHttpError::InvalidJson { service, operation }))
}

pub(crate) async fn inspect_json_response(
    response: Response,
    service: &'static str,
    operation: &'static str,
) -> Result<InspectedJsonResponse> {
    let status = response.status();
    let limit = if status.is_success() {
        MAX_EXTERNAL_JSON_BODY_BYTES
    } else {
        MAX_EXTERNAL_ERROR_BODY_BYTES
    };
    let (body, body_truncated) = read_bounded_body(response, limit, service, operation).await?;
    if status.is_success() && body_truncated {
        return Err(anyhow::Error::new(ExternalHttpError::BodyTooLarge {
            service,
            operation,
            limit_bytes: limit,
        }));
    }

    let mut value = match serde_json::from_slice::<Value>(&body) {
        Ok(value) => value,
        Err(_) if status.is_success() => {
            return Err(anyhow::Error::new(ExternalHttpError::InvalidJson {
                service,
                operation,
            }));
        }
        Err(_) => {
            let mut object = Map::new();
            object.insert("non_json_response".to_owned(), Value::Bool(true));
            Value::Object(object)
        }
    };
    redact_credentials(&mut value);
    if !status.is_success() {
        value = project_rejected_response_diagnostics(value);
    }
    if body_truncated {
        if let Value::Object(object) = &mut value {
            object.insert("body_truncated".to_owned(), Value::Bool(true));
        } else {
            value = serde_json::json!({
                "body_truncated": true,
                "response_type": value_type_name(&value),
            });
        }
    }
    Ok(InspectedJsonResponse {
        status,
        body: value,
    })
}

async fn read_bounded_body(
    mut response: Response,
    limit: usize,
    service: &'static str,
    operation: &'static str,
) -> Result<(Vec<u8>, bool)> {
    let mut body = Vec::with_capacity(limit.min(8 * 1024));
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| anyhow::Error::new(ExternalHttpError::BodyRead { service, operation }))?
    {
        let remaining = limit.saturating_sub(body.len());
        if chunk.len() > remaining {
            body.extend_from_slice(&chunk[..remaining]);
            return Ok((body, true));
        }
        body.extend_from_slice(&chunk);
    }
    Ok((body, false))
}

fn extract_allowlisted_error_code(body: &[u8]) -> &'static str {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("code")
                .or_else(|| value.get("error"))
                .and_then(Value::as_str)
                .and_then(allowlisted_external_error_code)
        })
        .unwrap_or("unclassified")
}

fn allowlisted_external_error_code(value: &str) -> Option<&'static str> {
    Some(match value {
        "access_denied" => "access_denied",
        "bad_admission_request" => "bad_admission_request",
        "bad_media_admission_request" => "bad_media_admission_request",
        "code_not_found" => "code_not_found",
        "invalid_client" => "invalid_client",
        "invalid_grant" => "invalid_grant",
        "invalid_request" => "invalid_request",
        "invalid_scope" => "invalid_scope",
        "invalid_session" => "invalid_session",
        "media_admission_token_expired" => "media_admission_token_expired",
        "media_admission_token_superseded" => "media_admission_token_superseded",
        "missing_bearer_token" => "missing_bearer_token",
        "missing_media_admission" => "missing_media_admission",
        "missing_media_admission_token" => "missing_media_admission_token",
        "missing_session_token" => "missing_session_token",
        "missing_turn_admission" => "missing_turn_admission",
        "missing_turn_admission_token" => "missing_turn_admission_token",
        "not_found" => "not_found",
        "rate_limited" => "rate_limited",
        "server_error" => "server_error",
        "session_expired" => "session_expired",
        "session_inactive" => "session_inactive",
        "session_token_expired" => "session_token_expired",
        "session_token_superseded" => "session_token_superseded",
        "temporarily_unavailable" => "temporarily_unavailable",
        "turn_admission_token_expired" => "turn_admission_token_expired",
        "turn_admission_token_superseded" => "turn_admission_token_superseded",
        "unauthorized_client" => "unauthorized_client",
        "unsupported_grant_type" => "unsupported_grant_type",
        _ => return None,
    })
}

fn allowlisted_rejection_reason(value: &str) -> Option<&'static str> {
    Some(match value {
        "expectedTokenMissing" => "expectedTokenMissing",
        "expired" => "expired",
        "media_admission_refreshed" => "media_admission_refreshed",
        "missingRecord" => "missingRecord",
        "missingToken" => "missingToken",
        "remote_kill" => "remote_kill",
        "rendezvousExpired" => "rendezvousExpired",
        "revoked" => "revoked",
        "scopeMismatch" => "scopeMismatch",
        _ => return None,
    })
}

fn allowlisted_media_token_state(value: &str) -> Option<&'static str> {
    Some(match value {
        "active" => "active",
        "bound" => "bound",
        "expired" => "expired",
        "issued" => "issued",
        "leased" => "leased",
        "revoked" => "revoked",
        "superseded" => "superseded",
        _ => return None,
    })
}

fn redact_credentials(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if is_sensitive_key(key) {
                    *child = Value::String("<redacted>".to_owned());
                } else {
                    redact_credentials(child);
                }
            }
        }
        Value::Array(values) => {
            for child in values {
                redact_credentials(child);
            }
        }
        Value::String(text) => {
            if contains_inline_credential(text) {
                *text = "<redacted>".to_owned();
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn project_rejected_response_diagnostics(value: Value) -> Value {
    let Value::Object(object) = value else {
        return serde_json::json!({ "non_json_response": true });
    };
    let mut projected = Map::new();
    for (key, value) in object {
        if !is_allowed_rejection_diagnostic_key(&key) {
            continue;
        }
        let normalized_key = normalized_key(&key);
        let safe_value = match value {
            Value::String(text) => {
                let allowlisted = match normalized_key.as_str() {
                    "error" | "code" => allowlisted_external_error_code(&text),
                    "rejectreason"
                    | "mediatokenrevokedreason"
                    | "mediatokensessionrejectreason" => allowlisted_rejection_reason(&text),
                    "mediatokenstate" => allowlisted_media_token_state(&text),
                    _ if is_safe_diagnostic_text(&text) => Some(text.as_str()),
                    _ => None,
                };
                Value::String(allowlisted.unwrap_or("<redacted>").to_owned())
            }
            Value::Null | Value::Bool(_) | Value::Number(_) => value,
            Value::Array(_) | Value::Object(_) => Value::String("<redacted>".to_owned()),
        };
        projected.insert(key, safe_value);
    }
    Value::Object(projected)
}

fn is_allowed_rejection_diagnostic_key(key: &str) -> bool {
    let normalized = normalized_key(key);
    matches!(
        normalized.as_str(),
        "error"
            | "code"
            | "rejectreason"
            | "serverbuildfingerprint"
            | "statebackend"
            | "supportsmediaadmissionrefresh"
            | "mediatokenstate"
            | "mediatokenrevokedreason"
            | "mediatokensessionrejectreason"
            | "mediatokenrequestgeneration"
            | "mediatokensessionpresent"
            | "nonjsonresponse"
            | "bodytruncated"
    )
}

fn is_safe_diagnostic_text(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && !contains_inline_credential(value)
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b':' | b'/' | b' ')
        })
}

fn is_sensitive_key(key: &str) -> bool {
    let normalized = normalized_key(key);
    normalized.ends_with("token")
        || normalized.ends_with("password")
        || normalized.ends_with("secret")
        || normalized.ends_with("credential")
        || normalized.ends_with("credentials")
        || matches!(
            normalized.as_str(),
            "authorization" | "cookie" | "setcookie" | "apikey" | "codeverifier"
        )
}

fn normalized_key(key: &str) -> String {
    key.chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn contains_inline_credential(value: &str) -> bool {
    let normalized = value.to_ascii_lowercase();
    normalized.contains("bearer ")
        || normalized.contains("?st=")
        || normalized.contains("&st=")
        || normalized.contains("session_token=")
        || normalized.contains("access_token=")
        || normalized.contains("refresh_token=")
}

fn value_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_are_semantically_allowlisted_and_never_echo_arbitrary_bodies() {
        assert_eq!(
            extract_allowlisted_error_code(br#"{"error":"invalid_session"}"#),
            "invalid_session"
        );
        assert_eq!(
            extract_allowlisted_error_code(br#"{"error":"Bearer secret-value"}"#),
            "unclassified"
        );
        assert_eq!(
            extract_allowlisted_error_code(
                br#"{"error":"sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7"}"#,
            ),
            "unclassified"
        );
        assert_eq!(
            extract_allowlisted_error_code(b"sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7"),
            "unclassified"
        );

        let rendered = ExternalHttpError::Rejected {
            service: "test service",
            operation: "test operation",
            status: StatusCode::UNAUTHORIZED,
            error_code: extract_allowlisted_error_code(
                br#"{"error":"sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7"}"#,
            ),
            body_truncated: false,
        }
        .to_string();
        assert!(rendered.contains("code=unclassified"));
        assert!(!rendered.contains("sk_live_"));
    }

    #[test]
    fn diagnostic_json_redacts_credentials_but_keeps_state_fields() {
        let mut value = serde_json::json!({
            "sessionToken": "session-secret",
            "turnCredentials": { "password": "turn-secret" },
            "mediaTokenState": "revoked",
            "rejectReason": "remote_kill",
            "message": "Authorization: Bearer access-secret",
        });
        redact_credentials(&mut value);

        assert_eq!(value["sessionToken"], "<redacted>");
        assert_eq!(value["turnCredentials"], "<redacted>");
        assert_eq!(value["mediaTokenState"], "revoked");
        assert_eq!(value["rejectReason"], "remote_kill");
        assert_eq!(value["message"], "<redacted>");
    }

    #[test]
    fn rejected_response_projection_drops_unknown_fields_and_redacts_unsafe_diagnostics() {
        let projected = project_rejected_response_diagnostics(serde_json::json!({
            "error": "invalid_session",
            "rejectReason": "Bearer reflected-secret",
            "sessionId": "session-secret",
            "unknown": "arbitrary external text",
            "mediaTokenState": "revoked",
        }));
        assert_eq!(projected["error"], "invalid_session");
        assert_eq!(projected["rejectReason"], "<redacted>");
        assert_eq!(projected["mediaTokenState"], "revoked");
        assert!(projected.get("sessionId").is_none());
        assert!(projected.get("unknown").is_none());

        let projected = project_rejected_response_diagnostics(serde_json::json!({
            "error": "sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7",
            "code": "ghp_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "rejectReason": "token_shaped_reflected_secret",
            "mediaTokenState": "secret_state_0123456789",
        }));
        assert_eq!(projected["error"], "<redacted>");
        assert_eq!(projected["code"], "<redacted>");
        assert_eq!(projected["rejectReason"], "<redacted>");
        assert_eq!(projected["mediaTokenState"], "<redacted>");
    }
}
