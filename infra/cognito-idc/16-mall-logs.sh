#!/usr/bin/env bash
# Gateway tool RBAC (customer version): deliver the mall gateway's APPLICATION_LOGS (incl. Policy decisions such as
# "Policy evaluation denied request ... decision DENY") to CloudWatch Logs, 7-day retention. Idempotent.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
LG=/aws/vendedlogs/bedrock-agentcore/gateway/${PROJECT}-mall-gateway; SRC=${PROJECT}-mall-gw-logs; DST=${PROJECT}-mall-gw-cwl
aws logs create-log-group --region $R --log-group-name $LG 2>/dev/null || true
aws logs put-retention-policy --region $R --log-group-name $LG --retention-in-days 7
aws logs put-delivery-source --region $R --name $SRC --resource-arn $MALL_GW_ARN --log-type APPLICATION_LOGS >/dev/null
aws logs put-delivery-destination --region $R --name $DST \
  --delivery-destination-configuration "destinationResourceArn=arn:aws:logs:$R:$ACCOUNT_ID:log-group:$LG:*" >/dev/null
aws logs describe-deliveries --region $R --query "deliveries[?deliverySourceName=='$SRC'].id" --output text | grep -q . || \
  aws logs create-delivery --region $R --delivery-source-name $SRC --delivery-destination-arn arn:aws:logs:$R:$ACCOUNT_ID:delivery-destination:$DST >/dev/null
aws logs describe-deliveries --region $R --query "deliveries[?deliverySourceName=='$SRC'].{id:id,dst:deliveryDestinationArn}"
