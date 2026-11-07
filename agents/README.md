# agents/
AgentCore Runtime agent sources, one folder per identity track. Each folder is packaged by one infra script (linux/arm64 wheels from its `requirements.txt`); the S3 artifact key prefixes the scripts use (`agent/`, `agent_oauth/`, `agent_entra/`) are object keys in the artifacts bucket, not local paths, and were left unchanged.
- [`cognito-idc/`](cognito-idc/): the Cognito + IAM Identity Center agents (`obo`, `oauth`).
- [`entra-id/`](entra-id/): the Microsoft Entra ID agent.
