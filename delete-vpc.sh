#!/bin/bash
# delete-vpc.sh — inventory and delete EVERYTHING inside one or more VPCs, then the VPCs.
#   ./delete-vpc.sh --dry-run vpc-0ff1c679adade279a vpc-070312c601036c88c     # inventory only
#   ./delete-vpc.sh           vpc-0ff1c679adade279a vpc-070312c601036c88c     # delete (asks for DESTROY per VPC)
# Order: EKS clusters in the VPC -> ELB/ELBv2 + target groups -> EC2 instances (+ their EBS) -> RDS/ElastiCache (reported, not
# deleted unless --with-data) -> NAT GWs + EIPs -> VPC endpoints -> ENIs -> peering -> VPN GWs -> IGW -> subnets
# -> route tables -> NACLs -> security groups -> VPC. Not scoped by tag: anything in the VPC goes.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"; A="aws --region $REGION --output json"
DRY=false; WITH_DATA=false; VPCS=()
for a in "$@"; do case "$a" in --dry-run) DRY=true ;; --with-data) WITH_DATA=true ;; vpc-*) VPCS+=("$a") ;; *) echo "bad arg $a"; exit 1 ;; esac; done
((${#VPCS[@]})) || { echo "usage: $0 [--dry-run] [--with-data] vpc-id [vpc-id...]"; exit 1; }
run() { if $DRY; then echo "    [dry-run] $*"; else "$@"; fi; }
say() { echo "  - $*"; }

for VPC in "${VPCS[@]}"; do
  echo; echo "================ $VPC ================"
  $A ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null || { echo "not found in $REGION"; continue; }
  echo "name: $($A ec2 describe-vpcs --vpc-ids "$VPC" | jq -r '.Vpcs[0].Tags[]?|select(.Key=="Name").Value')   cidr: $($A ec2 describe-vpcs --vpc-ids "$VPC" | jq -r '.Vpcs[0].CidrBlock')"

  # ---------- inventory ----------
  EKS=$(for c in $($A eks list-clusters | jq -r '.clusters[]'); do [[ "$($A eks describe-cluster --name "$c" | jq -r '.cluster.resourcesVpcConfig.vpcId')" == "$VPC" ]] && echo "$c"; done)
  LBV2=$($A elbv2 describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancers[]|select(.VpcId==$v).LoadBalancerArn')
  LBV1=$($A elb describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancerDescriptions[]|select(.VPCId==$v).LoadBalancerName')
  TGS=$($A elbv2 describe-target-groups | jq -r --arg v "$VPC" '.TargetGroups[]|select(.VpcId==$v).TargetGroupArn')
  INST=$($A ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" | jq -r '.Reservations[].Instances[]|"\(.InstanceId) \(.Tags[]?|select(.Key=="Name").Value // "-")"')
  RDS=$($A rds describe-db-instances | jq -r --arg v "$VPC" '.DBInstances[]|select(.DBSubnetGroup.VpcId==$v).DBInstanceIdentifier')
  NAT=$($A ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available,pending" | jq -r '.NatGateways[].NatGatewayId')
  EPS=$($A ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" | jq -r '.VpcEndpoints[].VpcEndpointId')
  PEER=$($A ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC" | jq -r '.VpcPeeringConnections[]|select(.Status.Code!="deleted").VpcPeeringConnectionId'; $A ec2 describe-vpc-peering-connections --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC" | jq -r '.VpcPeeringConnections[]|select(.Status.Code!="deleted").VpcPeeringConnectionId')
  VGW=$($A ec2 describe-vpn-gateways --filters "Name=attachment.vpc-id,Values=$VPC" | jq -r '.VpnGateways[]|select(.State!="deleted").VpnGatewayId')
  IGW=$($A ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" | jq -r '.InternetGateways[].InternetGatewayId')
  SUBNETS=$($A ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" | jq -r '.Subnets[].SubnetId')
  RTS=$($A ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" | jq -r '.RouteTables[]|select(all(.Associations[]?; .Main!=true)).RouteTableId')
  NACLS=$($A ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" | jq -r '.NetworkAcls[]|select(.IsDefault==false).NetworkAclId')
  SGS=$($A ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" | jq -r '.SecurityGroups[]|select(.GroupName!="default").GroupId')
  ENIS=$($A ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" | jq -r '.NetworkInterfaces[]|"\(.NetworkInterfaceId) \(.Status) \(.Description)"')

  echo "inventory:"
  for x in "EKS:$EKS" "ELBv2:$LBV2" "ELB classic:$LBV1" "target groups:$TGS" "instances:$INST" "RDS:$RDS" "NAT:$NAT" "endpoints:$EPS" "peering:$PEER" "VPN GW:$VGW" "IGW:$IGW" "subnets:$SUBNETS" "route tables:$RTS" "NACLs:$NACLS" "SGs:$SGS"; do
    k="${x%%:*}"; v="${x#*:}"; [[ -n "$v" ]] && { echo "  $k:"; echo "$v" | sed 's/^/     /'; }; done
  [[ -n "$ENIS" ]] && { echo "  ENIs (anything not 'available' belongs to something still alive):"; echo "$ENIS" | sed 's/^/     /'; }
  [[ -n "$RDS" ]] && ! $WITH_DATA && echo "  !! RDS present — will NOT be deleted without --with-data; the VPC delete will fail until it is gone."

  $DRY && continue
  read -r -p "Delete everything above in $VPC? type DESTROY: " ans; [[ "$ans" == "DESTROY" ]] || { echo "skipped"; continue; }

  # ---------- delete ----------
  for c in $EKS; do say "eks $c"
    for ng in $($A eks list-nodegroups --cluster-name "$c" | jq -r '.nodegroups[]'); do $A eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" >/dev/null; $A eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng"; done
    for fp in $($A eks list-fargate-profiles --cluster-name "$c" | jq -r '.fargateProfileNames[]'); do $A eks delete-fargate-profile --cluster-name "$c" --fargate-profile-name "$fp" >/dev/null; $A eks wait fargate-profile-deleted --cluster-name "$c" --fargate-profile-name "$fp"; done
    $A eks delete-cluster --name "$c" >/dev/null; $A eks wait cluster-deleted --name "$c"; done
  for lb in $LBV2; do say "elbv2 $lb"; $A elbv2 delete-load-balancer --load-balancer-arn "$lb"; done
  for lb in $LBV1; do say "elb $lb"; $A elb delete-load-balancer --load-balancer-name "$lb"; done
  [[ -n "$LBV2$LBV1" ]] && sleep 30
  for tg in $TGS; do say "tg $tg"; $A elbv2 delete-target-group --target-group-arn "$tg" || true; done
  IDS=$(echo "$INST" | awk '{print $1}' | tr '\n' ' ')
  if [[ -n "${IDS// }" ]]; then say "terminate $IDS"; $A ec2 terminate-instances --instance-ids $IDS >/dev/null; $A ec2 wait instance-terminated --instance-ids $IDS; fi
  if $WITH_DATA; then for db in $RDS; do say "rds $db"; $A rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null; $A rds wait db-instance-deleted --db-instance-identifier "$db"; done
    for sg in $($A rds describe-db-subnet-groups | jq -r --arg v "$VPC" '.DBSubnetGroups[]|select(.VpcId==$v).DBSubnetGroupName'); do $A rds delete-db-subnet-group --db-subnet-group-name "$sg"; done; fi
  for n in $NAT; do say "nat $n"; $A ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null; done
  for n in $NAT; do $A ec2 wait nat-gateway-deleted --nat-gateway-ids "$n" 2>/dev/null || true; done
  for eip in $($A ec2 describe-addresses | jq -r '.Addresses[]|select(.AssociationId==null).AllocationId'); do say "eip $eip (unassociated)"; $A ec2 release-address --allocation-id "$eip" || true; done
  for ep in $EPS; do say "endpoint $ep"; $A ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" >/dev/null; done
  for p in $PEER; do say "peering $p"; $A ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$p" >/dev/null; done
  for g in $VGW; do say "vgw $g"; $A ec2 detach-vpn-gateway --vpn-gateway-id "$g" --vpc-id "$VPC"; done
  sleep 15
  for e in $($A ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" | jq -r '.NetworkInterfaces[].NetworkInterfaceId'); do
    att=$($A ec2 describe-network-interfaces --network-interface-ids "$e" | jq -r '.NetworkInterfaces[0].Attachment.AttachmentId // empty')
    [[ -n "$att" ]] && $A ec2 detach-network-interface --attachment-id "$att" --force 2>/dev/null || true
    say "eni $e"; for i in 1 2 3 4 5 6; do $A ec2 delete-network-interface --network-interface-id "$e" 2>/dev/null && break; sleep 10; done; done
  for i in $IGW; do say "igw $i"; $A ec2 detach-internet-gateway --internet-gateway-id "$i" --vpc-id "$VPC"; $A ec2 delete-internet-gateway --internet-gateway-id "$i"; done
  for s in $SUBNETS; do say "subnet $s"; $A ec2 delete-subnet --subnet-id "$s"; done
  for r in $RTS; do say "rt $r"; $A ec2 delete-route-table --route-table-id "$r"; done
  for n in $NACLS; do say "nacl $n"; $A ec2 delete-network-acl --network-acl-id "$n"; done
  for g in $SGS; do perms=$($A ec2 describe-security-groups --group-ids "$g" | jq -c '.SecurityGroups[0].IpPermissions'); [[ "$perms" != "[]" ]] && $A ec2 revoke-security-group-ingress --group-id "$g" --ip-permissions "$perms" >/dev/null 2>&1 || true; done
  for g in $SGS; do say "sg $g"; for i in 1 2 3 4 5 6; do $A ec2 delete-security-group --group-id "$g" 2>/dev/null && break; sleep 10; done; done
  say "vpc $VPC"; $A ec2 delete-vpc --vpc-id "$VPC" && { echo "  deleted $VPC"; "$(dirname "$0")/verify-vpc-deleted.sh" "$VPC" || true; } || echo "  !! delete-vpc failed — re-run --dry-run to see what is still attached (usually an ENI owned by a Lambda, EFS mount target, or RDS)"
done
