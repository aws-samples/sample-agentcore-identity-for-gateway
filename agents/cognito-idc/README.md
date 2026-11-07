# agents/cognito-idc/
Agents for the Cognito + IAM Identity Center track.
- [`obo/`](obo/): OBO data agent, Cognito JWT exchanged for an IdC token, Redshift as the user (`infra/cognito-idc/08-deploy-runtime.sh`).
- [`oauth/`](oauth/): 2LO / 3LO agent using AgentCore Identity (`infra/cognito-idc/12-deploy-oauth-runtime.sh`).
Each agent is self-contained: no imports between them.
