import unittest

from check_supabase_advisors import classify, findings


class AdvisorGateTests(unittest.TestCase):
    def test_unknown_response_fails_closed(self):
        with self.assertRaises(ValueError):
            list(findings({"unexpected": []}))

    def test_truncated_group_fails_closed(self):
        with self.assertRaises(ValueError):
            list(findings({"lints": [{"name": "test", "level": "WARN", "count": 2, "findings": [{}]}]}))

    def test_same_function_name_with_new_signature_is_unreviewed(self):
        contract = {"intentional": [{"lint": "rpc", "metadata": {"name": "f", "arguments": "a text"}}]}
        payload = {"lints": [{"name": "rpc", "level": "WARN", "metadata": {"name": "f", "arguments": "a uuid"}}]}
        self.assertEqual(len(classify(payload, contract)["unresolved"]), 1)

    def test_error_is_never_classified_as_intentional(self):
        metadata = {"name": "f"}
        contract = {"intentional": [{"lint": "rpc", "metadata": metadata}]}
        payload = {"lints": [{"name": "rpc", "level": "ERROR", "metadata": metadata}]}
        self.assertEqual(len(classify(payload, contract)["unresolved"]), 1)

    def test_platform_limitations_remain_unresolved(self):
        payload = {"lints": [{"name": "auth_leaked_password_protection", "level": "WARN"}]}
        self.assertEqual(len(classify(payload, {"intentional": []})["unresolved"]), 1)


if __name__ == "__main__":
    unittest.main()
