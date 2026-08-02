#!/usr/bin/env python3

import unittest

from check_cross_platform_interop import (
    _ubuntu_bonjour_checks,
    failed_contract_blockers,
    parse_rust_identifier_array,
    parse_rust_string_constants,
    source_tokens_are_ordered,
    swift_signature_selection_contract,
)


class SwiftSignatureSelectionContractTests(unittest.TestCase):
    def test_accepts_current_mldsa65_and_mldsa87_switch(self) -> None:
        source = """
        let hasPQCOrHybrid = offeredSuites.contains { $0.isPQCGroup }
        guard hasPQCOrHybrid else { return .ed25519 }
        switch pqcAlgorithm {
        case .mlDSA65, .mlDSA87:
            return pqcAlgorithm.wire
        case .ed25519:
            return .ed25519
        }
        """
        self.assertTrue(swift_signature_selection_contract(source))

    def test_accepts_legacy_mldsa65_ternary(self) -> None:
        source = "let algorithm = hasPQCOrHybrid ? .mlDSA65 : .ed25519"
        self.assertTrue(swift_signature_selection_contract(source))

    def test_rejects_switch_that_omits_mldsa87(self) -> None:
        source = """
        let hasPQCOrHybrid = offeredSuites.contains { $0.isPQCGroup }
        guard hasPQCOrHybrid else { return .ed25519 }
        switch pqcAlgorithm {
        case .mlDSA65:
            return pqcAlgorithm.wire
        case .ed25519:
            return .ed25519
        }
        """
        self.assertFalse(swift_signature_selection_contract(source))


class FailedContractBlockerTests(unittest.TestCase):
    def test_failed_required_check_becomes_a_blocker(self) -> None:
        checks = {
            "signature_selection_contract": {"ok": False, "detail": "swift=False"},
            "suite_catalog_parity": {"ok": False, "detail": "handled separately"},
            "trust_pinning_path": {"ok": True, "detail": "all true"},
        }
        self.assertEqual(
            failed_contract_blockers(
                checks,
                handled_checks={"suite_catalog_parity"},
            ),
            ["signature_selection_contract: swift=False"],
        )


class RustBonjourSourceParsingTests(unittest.TestCase):
    def test_parses_public_and_private_string_constants(self) -> None:
        source = '''
        const VERSION: &str = "2";
        pub const SERVICE_TYPE: &str = "_skybridge._tcp.local.";
        '''
        self.assertEqual(
            parse_rust_string_constants(source),
            {
                "VERSION": "2",
                "SERVICE_TYPE": "_skybridge._tcp.local.",
            },
        )

    def test_identifier_array_requires_the_exact_declared_constant(self) -> None:
        source = '''
        const OTHER: [&str; 1] = [txt_fields::PORT];
        const CANONICAL_BASE_TXT_KEYS: [&str; 2] = [
            txt_fields::VERSION,
            txt_fields::DEVICE_ID,
        ];
        '''
        self.assertEqual(
            parse_rust_identifier_array(source, "CANONICAL_BASE_TXT_KEYS"),
            ["txt_fields::VERSION", "txt_fields::DEVICE_ID"],
        )
        with self.assertRaisesRegex(ValueError, "must have one definition"):
            parse_rust_identifier_array(source, "MISSING")

    def test_startup_order_rejects_advertisement_before_listener_readiness(self) -> None:
        expected = ("listener_ready_rx", "DeviceDiscoveryManager::with_config", "discovery.start")
        self.assertTrue(
            source_tokens_are_ordered(
                "listener_ready_rx DeviceDiscoveryManager::with_config discovery.start",
                expected,
            )
        )
        self.assertFalse(
            source_tokens_are_ordered(
                "discovery.start listener_ready_rx DeviceDiscoveryManager::with_config",
                expected,
            )
        )

    def test_comments_strings_and_dead_constants_cannot_restore_browse_topology(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        valid = self.analyze(mdns, types, app)
        self.assertTrue(valid["ubuntu_bonjour_service_topology"]["ok"])

        mutated = mdns.replace(
            "    TRANSFER_SERVICE_TYPE,\n",
            '    // TRANSFER_SERVICE_TYPE,\n    "TRANSFER_SERVICE_TYPE",\n',
            1,
        )
        result = self.analyze(mutated, types, app)
        self.assertFalse(result["ubuntu_bonjour_service_topology"]["ok"])

    def test_v2_exact_field_equality_cannot_be_satisfied_by_a_comment(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        mutated = mdns.replace(
            "if actual_keys != expected_keys",
            "if actual_keys.is_superset(&expected_keys) /* actual_keys != expected_keys */",
        )
        result = self.analyze(mutated, types, app)
        self.assertFalse(result["ubuntu_bonjour_v2_parser_and_advertiser"]["ok"])

    def test_route_and_startup_require_connected_srv_and_listener_structure(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        txt_routed = mdns.replace(
            "SocketAddr::new(addr, info.get_port())",
            'SocketAddr::new(addr, txt_port) /* info.get_port() */',
        )
        route_result = self.analyze(txt_routed, types, app)
        self.assertFalse(route_result["ubuntu_bonjour_route_identity_and_startup"]["ok"])

        app_lines = app.splitlines()
        listener_line = next(
            index for index, line in enumerate(app_lines) if "let listener_ready_rx" in line
        )
        init_call_line = next(
            index
            for index, line in enumerate(app_lines)
            if "init_services(tcp_control_port)" in line
        )
        app_lines[listener_line], app_lines[init_call_line] = (
            app_lines[init_call_line],
            app_lines[listener_line],
        )
        early_advertise = "\n".join(app_lines)
        startup_result = self.analyze(mdns, types, early_advertise)
        self.assertFalse(startup_result["ubuntu_bonjour_route_identity_and_startup"]["ok"])

    def test_validators_and_conflict_detector_cannot_be_constant_results(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        constant_device_validator = mdns.replace(
            '''fn is_valid_device_id(value: &str) -> bool {
            value == value.trim()
                && (BONJOUR_MINIMUM_DEVICE_ID_BYTES..=BONJOUR_MAXIMUM_DEVICE_ID_BYTES)
                    .contains(&value.len())
                && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.'))
        }''',
            "fn is_valid_device_id(value: &str) -> bool { true }",
        )
        self.assertFalse(
            self.analyze(constant_device_validator, types, app)[
                "ubuntu_bonjour_v2_parser_and_advertiser"
            ]["ok"]
        )

        constant_conflict_detector = mdns.replace(
            "fingerprints.len() > 1",
            "false",
        )
        self.assertFalse(
            self.analyze(constant_conflict_detector, types, app)[
                "ubuntu_bonjour_route_identity_and_startup"
            ]["ok"]
        )

    def test_writer_and_parser_data_flow_reject_dead_or_extra_evidence(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        extra_writer_key = mdns.replace(
            'properties.insert(STRONG_OWNER_AUTHENTICATION_TXT_KEY, "1".to_string());',
            '''properties.insert(STRONG_OWNER_AUTHENTICATION_TXT_KEY, "1".to_string());
            properties.insert("attackerField", "1".to_string());''',
        )
        self.assertFalse(
            self.analyze(extra_writer_key, types, app)[
                "ubuntu_bonjour_v2_parser_and_advertiser"
            ]["ok"]
        )

        disconnected_properties = mdns.replace(
            "ServiceInfo::new(properties).map(ServiceInfo::enable_addr_auto);",
            "ServiceInfo::new(attacker_properties).map(ServiceInfo::enable_addr_auto);",
        )
        self.assertFalse(
            self.analyze(disconnected_properties, types, app)[
                "ubuntu_bonjour_v2_parser_and_advertiser"
            ]["ok"]
        )

        nonterminating_rejection = mdns.replace(
            "return Err(AdvertisementError::InvalidVersion2FieldSet);",
            'warn!("invalid field set");',
        )
        self.assertFalse(
            self.analyze(nonterminating_rejection, types, app)[
                "ubuntu_bonjour_v2_parser_and_advertiser"
            ]["ok"]
        )

    def test_dead_service_references_and_hardcoded_readiness_do_not_pass(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        dead_service_reference = mdns.replace(
            "services.push(REMOTE_SERVICE_TYPE);",
            "let _ = REMOTE_SERVICE_TYPE;",
        )
        self.assertFalse(
            self.analyze(dead_service_reference, types, app)[
                "ubuntu_bonjour_service_topology"
            ]["ok"]
        )

        hardcoded_readiness = app.replace(
            '''let p2p_runtime_ready = match p2p_manager.start() {
                Ok(()) => true,
                Err(error) => { false }
            };''',
            "let p2p_runtime_ready = true;",
        )
        self.assertFalse(
            self.analyze(mdns, types, hardcoded_readiness)[
                "ubuntu_bonjour_route_identity_and_startup"
            ]["ok"]
        )

    def test_cfg_test_duplicates_and_log_wording_do_not_affect_production_checks(self) -> None:
        mdns, types, app = self.valid_linux_fixture()
        with_test_duplicates = mdns + '''
        #[cfg(test)]
        mod tests {
            const SERVICE_TYPE: &str = "_invalid._tcp.local.";
            fn service_plan() {}
            fn is_valid_device_id(_: &str) -> bool { false }
        }
        '''
        result = self.analyze(with_test_duplicates, types, app)
        self.assertTrue(result["ubuntu_bonjour_service_topology"]["ok"])
        self.assertTrue(result["ubuntu_bonjour_v2_parser_and_advertiser"]["ok"])

        renamed_log = mdns.replace(
            'warn!("Quarantined conflicting Bonjour identity claims");',
            'warn!("Bonjour identity conflict isolated");',
        )
        self.assertTrue(
            self.analyze(renamed_log, types, app)[
                "ubuntu_bonjour_route_identity_and_startup"
            ]["ok"]
        )

    @staticmethod
    def analyze(mdns: str, types: str, app: str) -> dict:
        return _ubuntu_bonjour_checks(
            mdns,
            types,
            app,
            [
                "_skybridge._udp",
                "_skybridge._tcp",
                "_skybridge-xfer._tcp",
                "_skybridge-rd._tcp",
                "_skybridge-transfer._tcp",
                "_skybridge-remote._tcp",
            ],
            ["version", "deviceId", "pubKeyFP", "platform", "hs_soa"],
            ["port", "transferPort", "remotePort"],
            16,
            128,
            "^[0-9a-f]{64}$",
        )

    @staticmethod
    def valid_linux_fixture() -> tuple[str, str, str]:
        mdns = '''
        const BONJOUR_ADVERTISEMENT_VERSION: &str = "2";
        const STRONG_OWNER_AUTHENTICATION_TXT_KEY: &str = "hs_soa";
        const BONJOUR_MAXIMUM_TXT_WIRE_BYTES: usize = 200;
        const BONJOUR_MINIMUM_DEVICE_ID_BYTES: usize = 16;
        const BONJOUR_MAXIMUM_DEVICE_ID_BYTES: usize = 128;
        const CANONICAL_BASE_TXT_KEYS: [&str; 4] = [
            txt_fields::VERSION,
            txt_fields::DEVICE_ID,
            txt_fields::PUB_KEY_FP,
            txt_fields::PLATFORM,
        ];
        const CANONICAL_CONTROL_TXT_KEYS: [&str; 5] = [
            txt_fields::VERSION,
            txt_fields::DEVICE_ID,
            txt_fields::PUB_KEY_FP,
            txt_fields::PLATFORM,
            STRONG_OWNER_AUTHENTICATION_TXT_KEY,
        ];
        pub const SERVICE_TYPE: &str = "_skybridge._tcp.local.";
        pub const QUIC_SERVICE_TYPE: &str = "_skybridge._udp.local.";
        pub const REMOTE_SERVICE_TYPE: &str = "_skybridge-rd._tcp.local.";
        pub const TRANSFER_SERVICE_TYPE: &str = "_skybridge-xfer._tcp.local.";
        pub const LEGACY_REMOTE_SERVICE_TYPE: &str = "_skybridge-remote._tcp.local.";
        pub const LEGACY_TRANSFER_SERVICE_TYPE: &str = "_skybridge-transfer._tcp.local.";
        const BROWSE_SERVICE_TYPES: [&str; 6] = [
            SERVICE_TYPE,
            QUIC_SERVICE_TYPE,
            REMOTE_SERVICE_TYPE,
            TRANSFER_SERVICE_TYPE,
            LEGACY_REMOTE_SERVICE_TYPE,
            LEGACY_TRANSFER_SERVICE_TYPE,
        ];

        fn service_plan() {
            let services = vec![SERVICE_TYPE, QUIC_SERVICE_TYPE];
            services.push(REMOTE_SERVICE_TYPE);
            services.push(TRANSFER_SERVICE_TYPE);
            services
        }
        fn start_browse() {
            for service_type in BROWSE_SERVICE_TYPES {
                self.daemon.browse(service_type);
            }
        }
        fn is_valid_device_id(value: &str) -> bool {
            value == value.trim()
                && (BONJOUR_MINIMUM_DEVICE_ID_BYTES..=BONJOUR_MAXIMUM_DEVICE_ID_BYTES)
                    .contains(&value.len())
                && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.'))
        }
        fn is_valid_public_key_fingerprint(value: &str) -> bool {
            value.len() == 64
                && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }
        fn canonical_platform_token() {
            match platform {
                Platform::Linux | Platform::Ubuntu => Some("linux"),
            }
        }
        fn canonical_properties() {
            let properties = HashMap::from([
                (txt_fields::VERSION, BONJOUR_ADVERTISEMENT_VERSION),
                (txt_fields::DEVICE_ID, device.device_id),
                (txt_fields::PUB_KEY_FP, device.public_key_fingerprint),
                (txt_fields::PLATFORM, platform),
            ]);
            properties.insert(STRONG_OWNER_AUTHENTICATION_TXT_KEY, "1".to_string());
        }
        fn build_service_info() {
            let properties = Self::canonical_properties();
            ServiceInfo::new(properties).map(ServiceInfo::enable_addr_auto);
        }
        fn advertise_services() {
            Self::build_service_info();
        }
        fn classify_advertisement() {
            match version {
                version => Err(AdvertisementError::UnsupportedVersion(version)),
            }
        }
        fn parse_common() {
            match classify_advertisement(properties) {
                AdvertisementGeneration::Version2 => Self::parse_version2(properties),
            }
        }
        fn parse_version2() {
            if actual_keys != expected_keys {
                return Err(AdvertisementError::InvalidVersion2FieldSet);
            }
            let actual_wire_size = txt_wire_size(&fields);
            if actual_wire_size > BONJOUR_MAXIMUM_TXT_WIRE_BYTES {
                return Err(AdvertisementError::RecordTooLarge { actual: actual_wire_size });
            }
            fields.get(txt_fields::DEVICE_ID)
                .filter(|value| is_valid_device_id(value))
                .cloned().ok_or(AdvertisementError::InvalidDeviceId)?;
            fields.get(txt_fields::PUB_KEY_FP)
                .filter(|value| is_valid_public_key_fingerprint(value))
                .cloned().ok_or(AdvertisementError::InvalidPublicKeyFingerprint)?;
            fields.get(txt_fields::PLATFORM)
                .and_then(|value| canonical_platform(value))
                .ok_or(AdvertisementError::InvalidPlatform)?;
            if service_kind == ServiceKind::Control && field != Some("1") {
                return Err(AdvertisementError::InvalidStrongOwnerAuthentication);
            }
        }
        fn parse_resolved_service() {
            let addresses: Vec<SocketAddr> = info.get_addresses().iter()
                .map(|addr| SocketAddr::new(addr, info.get_port())).collect();
            let mut device = Self::parse_common(info.get_properties(), addresses, service_kind)?;
            Ok(device)
        }
        fn has_identity_conflict() {
            let fingerprints = index.values()
                .filter(|entry| entry.device_id == device_id)
                .map(|entry| entry.public_key_fingerprint.as_str())
                .filter(|fingerprint| !fingerprint.is_empty())
                .collect();
            fingerprints.len() > 1
        }
        fn handle_event() {
            ServiceIndexEntry {
                public_key_fingerprint: device.public_key_fingerprint.clone(),
            };
            let has_identity_conflict = Self::has_identity_conflict(&index, &device_id);
            if has_identity_conflict {
                discovered.write().remove(&device_id);
                warn!("Quarantined conflicting Bonjour identity claims");
                return;
            }
            Self::merge_device(existing, device);
            callback(&merged_device);
        }
        '''
        types = '''
        pub const DEVICE_ID: &str = "deviceId";
        pub const PUB_KEY_FP: &str = "pubKeyFP";
        pub const PLATFORM: &str = "platform";
        pub const VERSION: &str = "version";
        '''
        app = '''
        fn build_ui() {
            let listener_ready_rx = ready();
            let port = listener.local_addr().port();
            (Some(port), Some(listener));
            init_services(tcp_control_port);
        }
        fn init_services() {
            let p2p_runtime_ready = match p2p_manager.start() {
                Ok(()) => true,
                Err(error) => { false }
            };
            let discovery = DeviceDiscoveryManager::with_config();
            if let Some(control_port) = tcp_control_port.filter(|_| p2p_runtime_ready) {
                discovery.start(control_port);
            }
        }
        '''
        return mdns, types, app


if __name__ == "__main__":
    unittest.main()
