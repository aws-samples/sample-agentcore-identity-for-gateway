# agents/cognito-idc/oauth/
Second AgentCore Runtime (`rsidc_oauth_agent`) for the **2LO and 3LO** test cases. It is kept separate from the OBO agent in `../obo/`.
- `{"mode":"2lo"}`: `GetResourceOauth2Token(M2M)` returns the agent's own Cognito client-credentials token, which it uses to call the AgentCore Gateway tool `reporting___get_sales_report`.
- `{"mode":"3lo","return_url":…}`: `GetResourceOauth2Token(USER_FEDERATION)` returns either a consent URL and session URI, or the user's token from the Token Vault. With the token, the agent calls Cognito `userInfo`.
- Guard: if the vault token's email does not match the caller's inbound JWT email, it returns `IDENTITY_MISMATCH` and no data.
- No LLM, no Redshift or IdC permissions. Deployed by `infra/cognito-idc/12-deploy-oauth-runtime.sh`.
