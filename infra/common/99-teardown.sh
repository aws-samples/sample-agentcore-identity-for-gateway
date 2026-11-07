#!/usr/bin/env bash
# Teardown for what infra/common/agent-registry.py created: the Agent Registry records and the registry itself, in
# every Region where the script was run (default: Tokyo for the main registry, us-east-1 for Amazon Quick).
# Run this FIRST (order: common -> entra-id -> cognito-idc). Registries are found by NAME (${PROJECT}-registry, the
# NAME constant in agent-registry.py), so no state.env variable is needed.
#
# Usage: infra/common/99-teardown.sh [--dry-run] [--yes]
# Env  : REGISTRY_REGIONS  space-separated Regions to clean (default "ap-northeast-1 us-east-1"; the Regions used by
#                          REGISTRY_REGION in agent-registry.py)
#        REGISTRY_NAME     default ${PROJECT}-registry
set -euo pipefail; source "$(dirname "$0")/00-config.sh"; source "$(dirname "$0")/teardown-lib.sh"
for a in "$@"; do td_flag "$a" || { echo "usage: $0 [--dry-run] [--yes]" >&2; exit 2; }; done
REGISTRY_REGIONS=${REGISTRY_REGIONS:-"ap-northeast-1 us-east-1"}
REGISTRY_NAME=${REGISTRY_NAME:-${PROJECT}-registry}
need_prefix "$REGISTRY_NAME"

teardown() {
  local reg rid rec
  for reg in $REGISTRY_REGIONS; do
    for rid in $(ls_ aws agent-registry-control list-registries --region "$reg" --query "registries[?name=='$REGISTRY_NAME'].registryId" --output text); do
      for rec in $(ls_ aws agent-registry-control list-registry-records --region "$reg" --registry-id "$rid" --query 'registryRecords[].recordId' --output text); do
        del "Agent Registry record $rec in $rid ($reg)" aws agent-registry-control delete-registry-record --region "$reg" --registry-id "$rid" --record-id "$rec"; done
      del "Agent Registry $REGISTRY_NAME ($rid, $reg)" aws agent-registry-control delete-registry --region "$reg" --registry-id "$rid"
    done
  done
}

td_main teardown
td_finish
