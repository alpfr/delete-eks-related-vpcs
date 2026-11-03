#!/bin/bash
# verify-vpc-deleted.sh — confirm one or more VPCs are gone AND nothing that referenced them is still billing.
#   ./verify-vpc-deleted.sh vpc-0ff1c679adade279a vpc-070312c601036c88c
#   ./verify-vpc-deleted.sh --wait vpc-...        # poll up to 10 min for async deletions (NAT GWs, LBs, ENIs)
# Exit 0 = all clean, 1 = something remains (listed), 2 = usage/auth error.
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"; A="aws --region $REGION --output json"
WAIT=false; VPCS=()
for a in "$@"; do case "$a" in --wait) WAIT=true ;; vpc-*) VPCS+=("$a") ;; *) echo "bad arg $a"; exit 2 ;; esac; done
((${#VPCS[@]})) || { echo "usage: $0 [--wait] vpc-id [vpc-id...]"; exit 2; }
$A sts get-caller-identity >/dev/null || { echo "aws cli not authenticated"; exit 2; }
RC=0; red() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; RC=1; }; ok() { printf '  \033[32mOK\033[0m   %s\n' "$*"; }

check() {  # one pass for one VPC; returns 0 if clean
  local VPC="$1" fail=0 n
  echo "== $VPC ($REGION) =="
  if $A ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null 2>&1; then
    red "VPC still exists (state: $($A ec2 describe-vpcs --vpc-ids "$VPC" | jq -r '.Vpcs[0].State'))"; fail=1
    # when the VPC is still there, show what is blocking it
    for q in \
      "subnets|ec2 describe-subnets --filters Name=vpc-id,Values=$VPC|.Subnets[].SubnetId" \
      "ENIs|ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC|.NetworkInterfaces[]|\"\\(.NetworkInterfaceId) \\(.Status) \\(.Description)\"" \
      "IGW|ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC|.InternetGateways[].InternetGatewayId" \
      "NAT|ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC Name=state,Values=available,pending,deleting|.NatGateways[]|\"\\(.NatGatewayId) \\(.State)\"" \
      "endpoints|ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC|.VpcEndpoints[].VpcEndpointId" \
      "SGs|ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC|.SecurityGroups[]|select(.GroupName!=\"default\").GroupId" \
      "route tables|ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC|.RouteTables[]|select(all(.Associations[]?; .Main!=true)).RouteTableId" \
      "peering|ec2 describe-vpc-peering-connections --filters Name=requester-vpc-info.vpc-id,Values=$VPC|.VpcPeeringConnections[]|select(.Status.Code!=\"deleted\").VpcPeeringConnectionId" \
      "instances|ec2 describe-instances --filters Name=vpc-id,Values=$VPC Name=instance-state-name,Values=pending,running,stopping,stopped|.Reservations[].Instances[].InstanceId"; do
      IFS='|' read -r label cmd jq <<<"$q"
      n=$($A $cmd 2>/dev/null | jq -r "$jq" 2>/dev/null | sed '/^$/d')
      [[ -n "$n" ]] && { red "$label remaining:"; echo "$n" | sed 's/^/         /'; }
    done
  else
    ok "VPC not found (deleted)"
  fi
  # things that outlive a VPC and keep billing / referencing it
  n=$($A elbv2 describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancers[]|select(.VpcId==$v)|"\(.LoadBalancerName) \(.State.Code)"'); [[ -n "$n" ]] && { red "ELBv2 still referencing VPC: $n"; fail=1; } || ok "no ELBv2"
  n=$($A elbv2 describe-target-groups | jq -r --arg v "$VPC" '.TargetGroups[]|select(.VpcId==$v).TargetGroupName'); [[ -n "$n" ]] && { red "target groups: $n"; fail=1; } || ok "no target groups"
  n=$($A elb describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancerDescriptions[]|select(.VPCId==$v).LoadBalancerName'); [[ -n "$n" ]] && { red "classic ELB: $n"; fail=1; } || ok "no classic ELB"
  n=$(for c in $($A eks list-clusters | jq -r '.clusters[]'); do [[ "$($A eks describe-cluster --name "$c" | jq -r '.cluster.resourcesVpcConfig.vpcId')" == "$VPC" ]] && echo "$c"; done); [[ -n "$n" ]] && { red "EKS cluster: $n"; fail=1; } || ok "no EKS"
  n=$($A rds describe-db-subnet-groups | jq -r --arg v "$VPC" '.DBSubnetGroups[]|select(.VpcId==$v).DBSubnetGroupName'); [[ -n "$n" ]] && { red "RDS subnet groups: $n"; fail=1; } || ok "no RDS subnet groups"
  n=$($A ec2 describe-addresses | jq -r '.Addresses[]|select(.AssociationId==null)|.AllocationId'); [[ -n "$n" ]] && echo "  WARN unassociated EIPs in region (billing, may be from this VPC): $n" || ok "no unassociated EIPs"
  n=$($A ec2 describe-volumes --filters Name=status,Values=available | jq -r '.Volumes[]|"\(.VolumeId) \(.Size)GB"'); [[ -n "$n" ]] && echo "  WARN unattached EBS volumes in region (billing): $(echo $n)" || ok "no unattached EBS"
  n=$($A ec2 describe-vpc-peering-connections --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC" | jq -r '.VpcPeeringConnections[]|select(.Status.Code!="deleted").VpcPeeringConnectionId'); [[ -n "$n" ]] && { red "peering (accepter side): $n"; fail=1; }
  n=$($A ec2 describe-transit-gateway-vpc-attachments --filters "Name=vpc-id,Values=$VPC" "Name=state,Values=available,pending,deleting" | jq -r '.TransitGatewayVpcAttachments[].TransitGatewayAttachmentId'); [[ -n "$n" ]] && { red "TGW attachments: $n"; fail=1; } || ok "no TGW attachments"
  n=$($A logs describe-log-groups --log-group-name-prefix "/aws/vpc" | jq -r --arg v "$VPC" '.logGroups[]|select(.logGroupName|contains($v)).logGroupName'); [[ -n "$n" ]] && echo "  WARN flow-log log groups: $n"
  return $fail
}

for VPC in "${VPCS[@]}"; do
  if $WAIT; then
    for i in $(seq 1 20); do check "$VPC" >/dev/null 2>&1 && break; echo "  ... waiting (${i}/20, 30s)"; sleep 30; done
  fi
  check "$VPC" || RC=1
  echo
done
(( RC == 0 )) && echo "ALL CLEAN: ${VPCS[*]}" || echo "NOT CLEAN — see FAIL lines above (run delete-vpc.sh --dry-run <id> for the full inventory)"
exit $RC
