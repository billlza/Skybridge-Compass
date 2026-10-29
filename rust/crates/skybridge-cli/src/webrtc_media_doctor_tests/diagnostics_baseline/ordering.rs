use super::*;

#[test]
fn doctor_webrtc_media_orders_cross_source_diagnostics_by_timestamp() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-cross-source-time-order")?;
    let base = OffsetDateTime::now_utc() - time::Duration::seconds(60);
    let ts0 = (base + time::Duration::seconds(0))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts1 = (base + time::Duration::seconds(1))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts2 = (base + time::Duration::seconds(2))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts3 = (base + time::Duration::seconds(3))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts4 = (base + time::Duration::seconds(4))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts5 = (base + time::Duration::seconds(5))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts6 = (base + time::Duration::seconds(6))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts7 = (base + time::Duration::seconds(7))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts8 = (base + time::Duration::seconds(8))
        .format(&time::format_description::well_known::Rfc3339)?;
    let ts9 = (base + time::Duration::seconds(9))
        .format(&time::format_description::well_known::Rfc3339)?;

    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION9.jsonl"),
        format!(
            "{{\"timestamp\":\"{ts0}\",\"session\":\"SESSION9\",\"audioTxCaptured\":100,\"audioTxEncoded\":100,\"audioTxSent\":100}}\n\
             {{\"timestamp\":\"{ts7}\",\"session\":\"SESSION9\",\"audioTxCaptured\":200,\"audioTxEncoded\":200,\"audioTxSent\":200}}\n"
        ),
    )?;
    std::fs::write(
        artifact_dir.join("aa-SESSION9.status.log"),
        format!(
            "[{ts2}] stream-stats session=SESSION9 fps=32\n\
             [{ts3}] native-video-health session=SESSION9 state=rtpFlowing\n\
             [{ts4}] native-video-tx session=SESSION9 state=rtpFlowing fallbackMode=main visibleFrame=2056x1329 codedFrame=2056x1330 framesEncoded=120 framesSent=120 packetsSent=240 bytesSent=4096 codec=video/H264 encoder=VideoToolbox qualityLimit=none encodeFPS=32\n\
             [{ts5}] native-receiver-frame session=SESSION9 size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=remote-heartbeat\n\
             [{ts5}] native-render-frame session=SESSION9 size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view nativeRenderEvidenceSource=rtc-mtl-video-view nativePromotionState=visible-render-evidence uiSurface=remoteDesktopView\n\
             [{ts6}] audio-rx session=SESSION9 source=remote-heartbeat audioRxDatagrams=100 audioRxRecv=50 audioRxDecoded=49 audioRxPlayed=49 recvTotal=50 decodeTotal=49 playTotal=49 renderedFrames=48000 underflow=0 rebuffer=0 playbackDrop=0 jitterEvicted=0 engineRunning=true\n\
             [{ts8}] audio-rx session=SESSION9 source=remote-heartbeat audioRxDatagrams=240 audioRxRecv=120 audioRxDecoded=118 audioRxPlayed=119 recvTotal=120 decodeTotal=118 playTotal=119 renderedFrames=96000 underflow=0 rebuffer=0 playbackDrop=0 jitterEvicted=0 engineRunning=true\n"
        ),
    )?;
    std::fs::write(
        artifact_dir.join("zz-SESSION9.webrtc-media.jsonl"),
        format!(
            "{{\"timestamp\":\"{ts1}\",\"kind\":\"audioRxRolling\",\"session\":\"SESSION9\",\"audioRxDatagrams\":1,\"audioRxRecv\":1,\"audioRxDecoded\":0,\"audioRxPlayed\":0,\"recvTotal\":1,\"decodeTotal\":0,\"playTotal\":0,\"renderedFrames\":0,\"underflow\":0,\"rebuffer\":0,\"playbackDrop\":0,\"jitterEvicted\":0}}\n\
             {{\"timestamp\":\"{ts9}\",\"kind\":\"audioRxRolling\",\"session\":\"SESSION9\",\"audioRxDatagrams\":180,\"audioRxRecv\":90,\"audioRxDecoded\":88,\"audioRxPlayed\":89,\"recvTotal\":210,\"decodeTotal\":206,\"playTotal\":208,\"renderedFrames\":144000,\"underflow\":0,\"rebuffer\":0,\"playbackDrop\":0,\"jitterEvicted\":0}}\n"
        ),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION9",
    )?;

    assert!(doctor_check(&report, "audio_rx_decoded").ok);
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(report.fault_stage.is_none());
    Ok(())
}
