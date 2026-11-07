#!/usr/bin/env bash
# ra3.large single node (IdC requires RA3/Serverless). Publicly addressable but SG allows 5439 ONLY from:
#   - $MY_IPS (each /32, operator workstation egress IPs)
#   - $RT_NAT_EIP/32  (AgentCore Runtime egress via NAT GW)
# TLS is enforced server-side (parameter group require_ssl=true): plaintext connections are rejected.
# For production use a private cluster (publicly-accessible=false, VPC endpoints/peering) instead of public + /32 rules.
# Admin password is managed by Secrets Manager (never seen in plaintext).
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$IDC_REGION
VPC=$(aws ec2 describe-vpcs --region $R --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region $R --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text)

if [ -z "${RS_SG_ID:-}" ]; then
  save RS_SG_ID $(aws ec2 create-security-group --region $R --vpc-id $VPC --group-name ${PROJECT}-redshift-sg \
    --description "Redshift 5439 from operator IP and AgentCore runtime NAT EIP only" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-redshift-sg},{Key=Project,Value=${PROJECT}}]" --query GroupId --output text)
  aws ec2 revoke-security-group-egress --region $R --group-id $RS_SG_ID --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
fi
# One rule per source (idempotent: an existing rule is skipped without affecting the others).
allow() { aws ec2 authorize-security-group-ingress --region $R --group-id $RS_SG_ID --ip-permissions \
  "[{\"IpProtocol\":\"tcp\",\"FromPort\":5439,\"ToPort\":5439,\"IpRanges\":[{\"CidrIp\":\"$1/32\",\"Description\":\"$2\"}]}]" >/dev/null 2>&1 || true; }
allow $RT_NAT_EIP "AgentCore runtime NAT EIP"
for ip in $MY_IPS; do allow $ip "operator workstation"; done

aws redshift create-cluster-subnet-group --region $R --cluster-subnet-group-name ${PROJECT}-subnets \
  --description "${PROJECT} default VPC subnets" --subnet-ids $SUBNETS >/dev/null 2>&1 || true

# Parameter group: require_ssl=true. Created if missing; the parameter is (re)set on every run.
PG=${PROJECT}-redshift-pg
aws redshift describe-cluster-parameter-groups --region $R --parameter-group-name $PG >/dev/null 2>&1 || \
  aws redshift create-cluster-parameter-group --region $R --parameter-group-name $PG --parameter-group-family redshift-1.0 \
    --description "${PROJECT}: require_ssl" --tags Key=Project,Value=${PROJECT} >/dev/null
aws redshift modify-cluster-parameter-group --region $R --parameter-group-name $PG \
  --parameters ParameterName=require_ssl,ParameterValue=true >/dev/null

if ! aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID >/dev/null 2>&1; then
  aws redshift create-cluster --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID \
    --node-type ra3.large --cluster-type single-node --db-name $REDSHIFT_DB \
    --master-username rsadmin --manage-master-password \
    --cluster-subnet-group-name ${PROJECT}-subnets --vpc-security-group-ids $RS_SG_ID \
    --publicly-accessible --encrypted --port 5439 --cluster-parameter-group-name $PG \
    --redshift-idc-application-arn $REDSHIFT_IDC_APP_ARN \
    --tags Key=Project,Value=${PROJECT} >/dev/null
else  # existing cluster: associate the group (idempotent); the static parameter applies after a reboot
  CUR_PG=$(aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --query 'Clusters[0].ClusterParameterGroups[0].ParameterGroupName' --output text)
  if [ "$CUR_PG" != "$PG" ]; then
    aws redshift modify-cluster --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --cluster-parameter-group-name $PG >/dev/null
    aws redshift wait cluster-available --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID
    aws redshift reboot-cluster --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID >/dev/null   # brief outage; applies require_ssl
  fi
fi
aws redshift wait cluster-available --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID
save REDSHIFT_HOST $(aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --query 'Clusters[0].Endpoint.Address' --output text)
save REDSHIFT_ADMIN_SECRET_ARN $(aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --query 'Clusters[0].MasterPasswordSecretArn' --output text)
aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --query 'Clusters[0].{status:ClusterStatus,host:Endpoint.Address,public:PubliclyAccessible}'
aws ec2 describe-security-groups --region $R --group-ids $RS_SG_ID --query 'SecurityGroups[0].IpPermissions'
aws redshift describe-cluster-parameters --region $R --parameter-group-name $PG --query "Parameters[?ParameterName=='require_ssl'].[ParameterName,ParameterValue]" --output text
aws redshift describe-clusters --region $R --cluster-identifier $REDSHIFT_CLUSTER_ID --query 'Clusters[0].ClusterParameterGroups[0]'
