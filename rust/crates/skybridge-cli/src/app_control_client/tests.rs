use super::*;

const ID: &str = "2c6b817b-431f-4124-a4cf-a8325dcf0387";

#[test]
fn pipe_identity_and_instance_selection_fail_closed() {
    assert_eq!(select_pid(&[42], None).unwrap(), 42);
    assert_eq!(select_pid(&[42, 43], Some(43)).unwrap(), 43);
    for (pids, selected) in [
        (vec![], None),
        (vec![42, 43], None),
        (vec![42], Some(43)),
        (vec![0], None),
    ] {
        assert!(select_pid(&pids, selected).is_err());
    }
    verify_server_pid(42, 42).unwrap();
    assert!(verify_server_pid(42, 43).is_err());
    assert!(verify_server_pid(0, 0).is_err());
}

#[test]
fn response_envelope_requires_matching_identity_and_exact_outcome() {
    let good = json!({"protocol":PROTOCOL,"id":ID,"success":true,"result":{}});
    let line = |value: Value| {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        bytes
    };
    assert_eq!(decode_response(&line(good.clone()), ID).unwrap(), json!({}));
    for bad in [
        json!({"protocol":PROTOCOL,"id":"other","success":true,"result":{}}),
        json!({"protocol":"unknown","id":ID,"success":true,"result":{}}),
        json!({"protocol":PROTOCOL,"id":ID,"result":{}}),
        json!({"protocol":PROTOCOL,"id":ID,"success":true}),
        json!({"protocol":PROTOCOL,"id":ID,"success":true,"result":null}),
        json!({"protocol":PROTOCOL,"id":ID,"success":true,"result":{},"error":{"code":"failed","message":"failure","retryable":false}}),
        json!({"protocol":PROTOCOL,"id":ID,"success":false,"error":{"code":"retry","message":"failure","retryable":true}}),
    ] {
        assert!(decode_response(&line(bad), ID).is_err());
    }
    let duplicate = format!(
        "{{\"protocol\":\"{PROTOCOL}\",\"id\":\"{ID}\",\"id\":\"other\",\"success\":true,\"result\":{{}}}}\n"
    );
    assert!(decode_response(duplicate.as_bytes(), ID).is_err());
    assert_eq!(
        decode_response(&serde_json::to_vec(&good).unwrap(), ID)
            .unwrap_err()
            .code,
        "app_response_unconfirmed"
    );
    assert_eq!(
        decode_response(&vec![b' '; MAX_FRAME_BYTES + 1], ID)
            .unwrap_err()
            .code,
        "app_response_too_large"
    );
    let rejected = json!({"protocol":PROTOCOL,"id":ID,"success":false,"error":{"code":"generation_mismatch","message":"The generation changed","retryable":false}});
    assert_eq!(
        decode_response(&line(rejected), ID).unwrap_err().code,
        "generation_mismatch"
    );
}

#[tokio::test]
async fn framing_bounds_reads_and_does_not_accept_unterminated_response() {
    let request = encode_request(ID, "app.status", json!({})).unwrap();
    let parsed: Value = serde_json::from_slice(&request).unwrap();
    assert_eq!(parsed["id"], ID);
    assert!(encode_request("not-a-uuid", "app.status", json!({})).is_err());
    assert!(encode_request(ID, "app.unknown", json!({})).is_err());
    assert!(
        encode_request(
            ID,
            "app.status",
            json!({"value":"x".repeat(MAX_FRAME_BYTES)})
        )
        .is_err()
    );
    for (response, expected) in [
        (br#"{"success":true}"#.to_vec(), "app_response_unconfirmed"),
        (vec![b'x'; MAX_FRAME_BYTES + 1], "app_response_too_large"),
    ] {
        let (mut client, mut server) = tokio::io::duplex(MAX_FRAME_BYTES * 2);
        let expected_request = request.clone();
        let peer = tokio::spawn(async move {
            let mut received = vec![0; expected_request.len()];
            server.read_exact(&mut received).await.unwrap();
            assert_eq!(received, expected_request);
            server.write_all(&response).await.unwrap();
            server.shutdown().await.unwrap();
        });
        assert_eq!(
            exchange(&mut client, ID, &request).await.unwrap_err().code,
            expected
        );
        peer.await.unwrap();
    }
}

#[test]
fn results_reject_missing_host_fields_and_unallowlisted_settings_or_interfaces() {
    assert!(decode_result::<HostSnapshot>(json!({"generation":1,"enabled":true})).is_err());
    assert!(parse_settings(json!({"settings":{},"persistence":"persisted"})).is_err());
    assert!(parse_settings(json!({"settings":{"appearance.mode":{"value":"unknown","observed_value":"dark"}},"persistence":"persisted"})).is_err());
    assert!(parse_interfaces(json!({"interfaces":[{"interface_ref":"one","name":"A"},{"interface_ref":"one","name":"B"}]})).is_err());
    assert!(parse_interfaces(json!({"interfaces":[{"interface_ref":"","name":"A"}]})).is_err());
}

#[test]
fn host_and_settings_observations_cannot_contradict_their_state() {
    let valid = json!({"generation":7,"enabled":true,"state":"listening","session_count":0,"frames_sent":0});
    validate_host(&decode_result::<HostSnapshot>(valid.clone()).unwrap()).unwrap();
    let mut failed = valid.clone();
    failed["state"] = "failed".into();
    validate_host(&decode_result::<HostSnapshot>(failed).unwrap()).unwrap();
    for (field, value) in [
        ("state", json!("stopped")),
        ("enabled", json!(false)),
        ("generation", json!(0)),
    ] {
        let mut bad = valid.clone();
        bad[field] = value;
        assert!(validate_host(&decode_result::<HostSnapshot>(bad).unwrap()).is_err());
    }
    let mut invented = valid;
    invented["state"] = "request_registered".into();
    assert!(decode_result::<HostSnapshot>(invented).is_err());
    let inconsistent = json!({"appearance.mode":{"value":"dark","observed_value":"light"}});
    assert!(parse_settings(json!({"settings":inconsistent,"persistence":"persisted"})).is_err());
    assert!(parse_status(json!({"app_pid":42,"runtime_id":"windows_app_runtime","host":{"generation":0,"enabled":false,"state":"stopped","session_count":0,"frames_sent":0},"settings":inconsistent,"capabilities":[]}),42).is_err());
}
