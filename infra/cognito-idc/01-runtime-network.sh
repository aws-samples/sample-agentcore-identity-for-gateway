#!/usr/bin/env bash
# VPC for AgentCore Runtime: private subnets egress via a NAT GW with a fixed EIP,
# so Redshift's security group can allowlist exactly one IP for the agent.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=${PROJECT}-$2},{Key=Project,Value=${PROJECT}}]"; }

[ -z "${RT_VPC_ID:-}" ] && save RT_VPC_ID $(aws ec2 create-vpc --region $R --cidr-block 10.50.0.0/16 --tag-specifications "$(tag vpc rt-vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region $R --vpc-id $RT_VPC_ID --enable-dns-hostnames
[ -z "${RT_IGW_ID:-}" ] && { save RT_IGW_ID $(aws ec2 create-internet-gateway --region $R --tag-specifications "$(tag internet-gateway rt-igw)" --query InternetGateway.InternetGatewayId --output text); aws ec2 attach-internet-gateway --region $R --vpc-id $RT_VPC_ID --internet-gateway-id $RT_IGW_ID; }
[ -z "${RT_PUB_SUBNET:-}" ] && save RT_PUB_SUBNET $(aws ec2 create-subnet --region $R --vpc-id $RT_VPC_ID --cidr-block 10.50.0.0/24 --availability-zone-id apse1-az1 --tag-specifications "$(tag subnet rt-public)" --query Subnet.SubnetId --output text)
[ -z "${RT_PRIV_SUBNET_1:-}" ] && save RT_PRIV_SUBNET_1 $(aws ec2 create-subnet --region $R --vpc-id $RT_VPC_ID --cidr-block 10.50.1.0/24 --availability-zone-id apse1-az1 --tag-specifications "$(tag subnet rt-private-1)" --query Subnet.SubnetId --output text)
[ -z "${RT_PRIV_SUBNET_2:-}" ] && save RT_PRIV_SUBNET_2 $(aws ec2 create-subnet --region $R --vpc-id $RT_VPC_ID --cidr-block 10.50.2.0/24 --availability-zone-id apse1-az2 --tag-specifications "$(tag subnet rt-private-2)" --query Subnet.SubnetId --output text)

if [ -z "${RT_PUB_RTB:-}" ]; then
  save RT_PUB_RTB $(aws ec2 create-route-table --region $R --vpc-id $RT_VPC_ID --tag-specifications "$(tag route-table rt-public)" --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --region $R --route-table-id $RT_PUB_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $RT_IGW_ID >/dev/null
  aws ec2 associate-route-table --region $R --route-table-id $RT_PUB_RTB --subnet-id $RT_PUB_SUBNET >/dev/null
fi
if [ -z "${RT_NAT_ID:-}" ]; then
  save RT_EIP_ALLOC $(aws ec2 allocate-address --region $R --domain vpc --tag-specifications "$(tag elastic-ip rt-nat-eip)" --query AllocationId --output text)
  save RT_NAT_ID $(aws ec2 create-nat-gateway --region $R --subnet-id $RT_PUB_SUBNET --allocation-id $RT_EIP_ALLOC --tag-specifications "$(tag natgateway rt-nat)" --query NatGateway.NatGatewayId --output text)
  aws ec2 wait nat-gateway-available --region $R --nat-gateway-ids $RT_NAT_ID
fi
save RT_NAT_EIP $(aws ec2 describe-addresses --region $R --allocation-ids $RT_EIP_ALLOC --query 'Addresses[0].PublicIp' --output text)
if [ -z "${RT_PRIV_RTB:-}" ]; then
  save RT_PRIV_RTB $(aws ec2 create-route-table --region $R --vpc-id $RT_VPC_ID --tag-specifications "$(tag route-table rt-private)" --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --region $R --route-table-id $RT_PRIV_RTB --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $RT_NAT_ID >/dev/null
  for s in $RT_PRIV_SUBNET_1 $RT_PRIV_SUBNET_2; do aws ec2 associate-route-table --region $R --route-table-id $RT_PRIV_RTB --subnet-id $s >/dev/null; done
fi
# Runtime SG: no inbound (AgentCore invokes via its own control plane), egress only.
[ -z "${RT_SG_ID:-}" ] && save RT_SG_ID $(aws ec2 create-security-group --region $R --vpc-id $RT_VPC_ID --group-name ${PROJECT}-runtime-sg --description "AgentCore runtime ENIs - egress only" --tag-specifications "$(tag security-group runtime-sg)" --query GroupId --output text)
echo "Runtime NAT EIP: $RT_NAT_EIP"
