# Shared configuration for all infra scripts. Source this file; do not execute.
export AWS_PROFILE=default
export PROJECT=rsidc
export IDC_REGION=ap-east-1          # IAM Identity Center + Redshift
export RT_REGION=ap-southeast-1      # AgentCore Runtime (nearest region with AgentCore)
# Your IdC ids: export them, put them in infra/state.env (gitignored), or edit the defaults below.
export IDC_INSTANCE_ARN=${IDC_INSTANCE_ARN:-arn:aws:sso:::instance/<idc-instance-id>}
export IDENTITY_STORE_ID=${IDENTITY_STORE_ID:-<identity-store-id>}
export ACCOUNT_ID=${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}   # looked up, not hardcoded
export REDSHIFT_CLUSTER_ID=${PROJECT}-cluster
export REDSHIFT_DB=dev
export REDSHIFT_NAMESPACE=AWSIDC     # IdC identities appear in Redshift as AWSIDC:<user> / AWSIDC:<group>
# Operator egress IPs (space-separated). Corp networks may NAT different ports via different IPs, so detect
# the IP actually used for TCP 5439 (portquiz) as well as HTTPS (checkip).
export MY_IPS=${MY_IPS:-"$( (curl -s --max-time 5 http://portquiz.net:5439 | grep -o 'Your IP: [0-9.]*' | cut -d' ' -f3; curl -s https://checkip.amazonaws.com) | sort -u | xargs)"}
export ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # repo root; infra/state.env stays at its original location
STATE_FILE="$ROOT/infra/state.env"
touch "$STATE_FILE"; source "$STATE_FILE"
case "$IDC_INSTANCE_ARN$IDENTITY_STORE_ID" in *"<"*) echo "ERROR: set IDC_INSTANCE_ARN and IDENTITY_STORE_ID (see infra/README.md)" >&2; return 1 ;; esac
save() { sed -i '' "/^export $1=/d" "$STATE_FILE"; echo "export $1=$2" >> "$STATE_FILE"; export "$1=$2"; }
