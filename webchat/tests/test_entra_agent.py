"""Offline checks for the Entra agent's caller allowlist (T-04) and oid identity guard. No AWS: SDKs are stubbed.
Run from the repo root:  .venv/bin/python webchat/tests/test_entra_agent.py"""
import importlib.util, os, sys, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.update(AWS_REGION="us-east-1", CP_ENTRA="cp", MALL_API_APP_ID="m", ENTRA_GW_URL="https://gw",
                  ENTRA_ALLOWED_CLIENT_IDS=" AAA , bbb ,")
for name in ("boto3", "urllib3", "bedrock_agentcore", "bedrock_agentcore.runtime", "bedrock_agentcore.runtime.context"):
    sys.modules[name] = mock.MagicMock()
sys.modules["bedrock_agentcore.runtime"].BedrockAgentCoreApp = lambda: types.SimpleNamespace(entrypoint=lambda f: f)
spec = importlib.util.spec_from_file_location("entra_agent", os.path.join(HERE, "..", "..", "agents", "entra-id", "main.py"))
agent = importlib.util.module_from_spec(spec); spec.loader.exec_module(agent)


class Caller(unittest.TestCase):
    def test_env_parsed(self):
        self.assertEqual(agent.ALLOWED_CLIENTS, {"aaa", "bbb"})

    def test_allowed_v2_and_v1(self):
        self.assertIsNone(agent.check_caller({"azp": "AAA"}, agent.ALLOWED_CLIENTS))
        self.assertIsNone(agent.check_caller({"appid": "bbb"}, agent.ALLOWED_CLIENTS))

    def test_rejected(self):
        for c in ({"azp": "evil"}, {}, {"appid": "evil"}):
            self.assertIsNotNone(agent.check_caller(c, agent.ALLOWED_CLIENTS))
        self.assertIn("fail closed", agent.check_caller({"azp": "aaa"}, set()))

    def test_entrypoint_rejects_disallowed_client(self):
        import base64, json
        tok = "h." + base64.urlsafe_b64encode(json.dumps({"azp": "evil", "oid": "o"}).encode()).decode() + ".s"
        ctx = types.SimpleNamespace(request_headers={"Authorization": f"Bearer {tok}"})
        with mock.patch.object(agent.BedrockAgentCoreContext, "get_workload_access_token", return_value="wat"):
            r = agent.invoke({"mode": "2lo"}, ctx)
        self.assertIn("caller not allowed", r["error"])

    def test_3lo_guard_uses_oid(self):
        agent.token = lambda *a, **k: {"accessToken": "x"}
        for me_id, caller, want in (("O1", "o1", "TOKEN_FROM_VAULT"), ("O2", "o1", "IDENTITY_MISMATCH"), ("O1", None, "IDENTITY_MISMATCH")):
            agent.http_json = lambda url, t, b=None, me_id=me_id: (200, {"id": me_id, "userPrincipalName": "same@x"})
            self.assertEqual(agent.three_lo("w", {"return_url": "u"}, caller)["status"], want)


if __name__ == "__main__":
    unittest.main(verbosity=2)
