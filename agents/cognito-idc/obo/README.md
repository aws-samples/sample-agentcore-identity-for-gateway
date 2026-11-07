# agents/cognito-idc/obo/
AgentCore Runtime entrypoint (`main.py`) and Redshift access (`redshift_tools.py`).
- Identity: the caller's bearer JWT is exchanged once via `sso-oauth:CreateTokenWithIAM` for an IdC access token, which is cached per JWT inside the session. Redshift is then called with `token_type=ACCESS_TOKEN`, so the session runs as `AWSIDC:<user>`.
- Fails closed: with no JWT there is no connection. There is never a fallback to the runtime role's credentials.
- Payload `{"sql": ...}` is deterministic (used by the tests). `{"prompt": ...}` runs the Strands + Claude agent with the `run_sql` tool.
- Model: `MODEL_ID` (default an Anthropic Claude cross-Region inference profile on Amazon Bedrock), invoked from AgentCore Runtime in ap-southeast-1. The question and query results are sent to the model; its output can be inaccurate. See "Generative AI in this sample" in the repo README.
- Deployed by `infra/cognito-idc/08-deploy-runtime.sh` (linux/arm64 wheels from `requirements.txt`).
