# infra/common/
Provisioning pieces used by **both** identity tracks (Cognito + IAM Identity Center, and Microsoft Entra ID).
- `00-config.sh`: shared settings (regions, IdC instance, names, operator IPs). Source it; do not execute it. It exports `ROOT` (the repository root) and `save`, which writes resource IDs to `infra/state.env`.
- `run.sh`: runs any command with the shared config and state loaded, e.g. `infra/common/run.sh bash infra/cognito-idc/16-mall-gateway.sh`.
- `agent-registry.py`: catalogues the runtimes and gateways of both tracks in AWS Agent Registry. It writes each record body to `infra/<track>/registry/`.
- `lambda/mall_tools/`: the mall Gateway Lambda target. Deployed by `cognito-idc/16-mall-gateway.sh` and re-used (same function, same `tools.json`) by `entra-id/02-entra-gateway.sh`.
- `teardown-lib.sh`: helpers shared by the three `99-teardown.sh` scripts (`--dry-run`, `--yes`, not-found-safe deletes, `rsidc` prefix guard). `99-teardown.sh`: deletes the Agent Registry records and registries created by `agent-registry.py` (found by name `rsidc-registry`; Regions from `REGISTRY_REGIONS`, default `ap-northeast-1 us-east-1`). Run it first.
Boundary: only add a file here if both tracks use it. Track-specific steps live in `../cognito-idc/` or `../entra-id/`. `state.env` stays one level up, at `infra/state.env`.
