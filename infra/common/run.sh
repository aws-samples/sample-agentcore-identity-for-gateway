#!/usr/bin/env bash
# Run any command with the shared config/state loaded, e.g.: infra/common/run.sh python3 infra/cognito-idc/05-seed-redshift.py
set -euo pipefail; source "$(cd "$(dirname "$0")" && pwd)/00-config.sh"; exec "$@"
