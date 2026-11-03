#!/bin/bash
# delete-eks.sh — delete an EKS cluster and, optionally, the VPC it lives in.
#   ./delete-eks.sh --dry-run demo-eks            inventory: nodegroups, LB services/ingresses, PVCs, what else shares the VPC
#   ./delete-eks.sh demo-eks                      delete the cluster (K8s LBs/PVCs first), keep the VPC
#   ./delete-eks.sh --with-vpc demo-eks           ... then delete the VPC IF nothing foreign remains (RDS, other clusters' LBs)
#   ./delete-eks.sh --with-vpc --force-vpc demo-eks   delete the VPC even with foreign LBs (never RDS unless --with-data)
# Order: K8s Services type=LoadBalancer + Ingresses (LB controller removes ALB/NLB/TGs) -> PVCs (EBS/EFS CSI) ->
#        nodegroups -> Fargate profiles -> add-ons -> cluster -> cluster SG / leftover ENIs -> CloudWatch log group
#        -> [--with-vpc] delete-vpc.sh on the cluster's VPC -> verify-vpc-deleted.sh
# eksctl-created clusters: prefer `eksctl delete cluster --name X --wait` (removes its CloudFormation stacks); this script
# still works but leaves the eksctl stacks to delete by hand.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"; A="aws --region $REGION --output json"
DRY=false; WITH_VPC=false; FORCE_VPC=false; WITH_DATA=false; CLUSTER=""
for a in "$@"; do case "$a" in --dry-run) DRY=true ;; --with-vpc) WITH_VPC=true ;; --force-vpc) FORCE_VPC=true ;; --with-data) WITH_DATA=true ;; -*) echo "bad flag $a"; exit 2 ;; *) CLUSTER="$a" ;; esac; done
[[ -n "$CLUSTER" ]] || { echo "usage: $0 [--dry-run] [--with-vpc [--force-vpc] [--with-data]] <eks-cluster-name>"; exit 2; }
run() { if $DRY; then echo "    [dry-run] $*"; else "$@"; fi; }
say() { echo "  - $*"; }

echo "== EKS cluster $CLUSTER ($REGION) =="
DESC=$($A eks describe-cluster --name "$CLUSTER" 2>/dev/null) || { echo "cluster not found"; exit 1; }
VPC=$(jq -r '.cluster.resourcesVpcConfig.vpcId' <<<"$DESC"); CSG=$(jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId // empty' <<<"$DESC")
echo "version $(jq -r .cluster.version <<<"$DESC")  status $(jq -r .cluster.status <<<"$DESC")  vpc $VPC  cluster-sg ${CSG:-none}"
NGS=$($A eks list-nodegroups --cluster-name "$CLUSTER" | jq -r '.nodegroups[]')
FPS=$($A eks list-fargate-profiles --cluster-name "$CLUSTER" | jq -r '.fargateProfileNames[]')
ADDONS=$($A eks list-addons --cluster-name "$CLUSTER" | jq -r '.addons[]')
echo "nodegroups: ${NGS:-none}"; echo "fargate: ${FPS:-none}"; echo "addons: $(echo $ADDONS)"

# ---------- Kubernetes-side inventory (needs API access) ----------
KC=$(mktemp); K="kubectl --kubeconfig $KC"
if $A eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$KC" >/dev/null 2>&1 && $K get ns >/dev/null 2>&1; then
  LBSVC=$($K get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|"\(.metadata.namespace)/\(.metadata.name)"')
  INGS=$($K get ingress -A -o json 2>/dev/null | jq -r '.items[]|"\(.metadata.namespace)/\(.metadata.name)"')
  PVCS=$($K get pvc -A -o json | jq -r '.items[]|"\(.metadata.namespace)/\(.metadata.name) \(.spec.storageClassName // "-")"')
  echo "LoadBalancer services:"; echo "${LBSVC:-  none}" | sed 's/^/   /'
  echo "ingresses:";            echo "${INGS:-  none}"  | sed 's/^/   /'
  echo "PVCs (EBS/EFS deleted with them if reclaimPolicy=Delete):"; echo "${PVCS:-  none}" | sed 's/^/   /'
  K8S_OK=true
else
  echo "!! cannot reach the Kubernetes API (no access entry / cluster unhealthy). LBs created by the cluster must be deleted by hand afterwards."
  K8S_OK=false; LBSVC=""; INGS=""; PVCS=""
fi

# ---------- what else lives in this VPC (foreign = not this cluster's) ----------
echo "== other tenants of $VPC =="
OTHER_LB=$($A elbv2 describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancers[]|select(.VpcId==$v)|.LoadBalancerArn' | while read -r arn; do
  tags=$($A elbv2 describe-tags --resource-arns "$arn" | jq -r '.TagDescriptions[0].Tags[]|"\(.Key)=\(.Value)"')
  grep -q "^elbv2.k8s.aws/cluster=$CLUSTER$" <<<"$tags" && continue; echo "$arn ($(grep -m1 'elbv2.k8s.aws/cluster' <<<"$tags" || echo 'no cluster tag'))"; done)
RDS=$($A rds describe-db-instances | jq -r --arg v "$VPC" '.DBInstances[]|select(.DBSubnetGroup.VpcId==$v).DBInstanceIdentifier')
OTHER_EKS=$(for c in $($A eks list-clusters | jq -r '.clusters[]'); do [[ "$c" == "$CLUSTER" ]] && continue; [[ "$($A eks describe-cluster --name "$c" | jq -r '.cluster.resourcesVpcConfig.vpcId')" == "$VPC" ]] && echo "$c"; done)
OTHER_EC2=$($A ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=running,stopped" | jq -r --arg c "$CLUSTER" '.Reservations[].Instances[]|select((.Tags//[])|map(select(.Key=="eks:cluster-name" and .Value==$c))|length==0)|"\(.InstanceId) \((.Tags//[])|map(select(.Key=="Name"))|.[0].Value // "-")"')
[[ -n "$OTHER_LB" ]]  && { echo "load balancers NOT owned by $CLUSTER:"; echo "$OTHER_LB" | sed 's/^/   /'; } || echo "no foreign load balancers"
[[ -n "$RDS" ]]       && { echo "RDS instances:"; echo "$RDS" | sed 's/^/   /'; } || echo "no RDS"
[[ -n "$OTHER_EKS" ]] && { echo "other EKS clusters: $OTHER_EKS"; } || echo "no other EKS clusters"
[[ -n "$OTHER_EC2" ]] && { echo "EC2 not belonging to $CLUSTER:"; echo "$OTHER_EC2" | sed 's/^/   /'; } || echo "no foreign EC2"
FOREIGN=false; [[ -n "$OTHER_LB$RDS$OTHER_EKS$OTHER_EC2" ]] && FOREIGN=true

if $DRY; then
  echo; echo "dry run. VPC deletion would be: $($WITH_VPC && { $FOREIGN && ( $FORCE_VPC && echo 'FORCED despite foreign resources' || echo 'REFUSED (foreign resources present; --force-vpc to override, RDS needs --with-data)' ) || echo 'allowed (VPC only hosts this cluster)'; } || echo 'not requested')"
  rm -f "$KC"; exit 0
fi
read -r -p "Delete EKS cluster $CLUSTER$($WITH_VPC && echo " AND VPC $VPC")? type DESTROY: " ans; [[ "$ans" == "DESTROY" ]] || exit 1

# ---------- 1. Kubernetes resources that own AWS objects ----------
if $K8S_OK; then
  for s in $LBSVC; do say "svc $s"; $K -n "${s%%/*}" delete svc "${s##*/}" --wait=false; done
  for i in $INGS;  do say "ingress $i"; $K -n "${i%%/*}" delete ingress "${i##*/}" --wait=false; done
  if [[ -n "$LBSVC$INGS" ]]; then
    say "waiting for the LB controller to remove $CLUSTER's load balancers"
    for t in $(seq 1 30); do
      left=$($A elbv2 describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancers[]|select(.VpcId==$v).LoadBalancerArn' | while read -r arn; do $A elbv2 describe-tags --resource-arns "$arn" | jq -r --arg c "$CLUSTER" '.TagDescriptions[0].Tags[]|select(.Key=="elbv2.k8s.aws/cluster" and .Value==$c)|.Value'; done | wc -l)
      (( left == 0 )) && break; sleep 10; done
  fi
  for p in $(echo "$PVCS" | awk '{print $1}'); do [[ -n "$p" ]] && { say "pvc $p"; $K -n "${p%%/*}" delete pvc "${p##*/}" --wait=false; }; done
  sleep 20
fi

# ---------- 2. EKS ----------
for ng in $NGS; do say "nodegroup $ng"; $A eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" >/dev/null; done
for ng in $NGS; do $A eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$ng"; done
for fp in $FPS; do say "fargate $fp"; $A eks delete-fargate-profile --cluster-name "$CLUSTER" --fargate-profile-name "$fp" >/dev/null; $A eks wait fargate-profile-deleted --cluster-name "$CLUSTER" --fargate-profile-name "$fp"; done
for ad in $ADDONS; do say "addon $ad"; $A eks delete-addon --cluster-name "$CLUSTER" --addon-name "$ad" --preserve >/dev/null 2>&1 || true; done
say "cluster $CLUSTER"; $A eks delete-cluster --name "$CLUSTER" >/dev/null; $A eks wait cluster-deleted --name "$CLUSTER"; echo "  cluster deleted"

# ---------- 3. leftovers EKS does not remove ----------
for arn in $($A elbv2 describe-load-balancers | jq -r --arg v "$VPC" '.LoadBalancers[]|select(.VpcId==$v).LoadBalancerArn'); do
  $A elbv2 describe-tags --resource-arns "$arn" | jq -e --arg c "$CLUSTER" '.TagDescriptions[0].Tags[]|select(.Key=="elbv2.k8s.aws/cluster" and .Value==$c)' >/dev/null && { say "orphan LB $arn"; $A elbv2 delete-load-balancer --load-balancer-arn "$arn"; }; done
for tg in $($A elbv2 describe-target-groups | jq -r --arg v "$VPC" '.TargetGroups[]|select(.VpcId==$v).TargetGroupArn'); do
  $A elbv2 describe-tags --resource-arns "$tg" | jq -e --arg c "$CLUSTER" '.TagDescriptions[0].Tags[]|select(.Key=="elbv2.k8s.aws/cluster" and .Value==$c)' >/dev/null && { say "orphan TG $tg"; $A elbv2 delete-target-group --target-group-arn "$tg" || true; }; done
for v in $($A ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" "Name=status,Values=available" | jq -r '.Volumes[].VolumeId'); do say "orphan EBS $v"; $A ec2 delete-volume --volume-id "$v"; done
for e in $($A ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" "Name=status,Values=available" "Name=description,Values=aws-K8S-i-*,Amazon EKS $CLUSTER" | jq -r '.NetworkInterfaces[].NetworkInterfaceId'); do say "orphan ENI $e"; $A ec2 delete-network-interface --network-interface-id "$e" || true; done
for g in $($A ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" | jq -r '.SecurityGroups[].GroupId'); do say "cluster SG $g"; for i in 1 2 3 4 5 6; do $A ec2 delete-security-group --group-id "$g" 2>/dev/null && break; sleep 10; done; done
$A logs delete-log-group --log-group-name "/aws/eks/$CLUSTER/cluster" 2>/dev/null && say "log group /aws/eks/$CLUSTER/cluster"
rm -f "$KC"

# ---------- 4. VPC ----------
if $WITH_VPC; then
  if $FOREIGN && ! $FORCE_VPC; then
    echo; echo "VPC $VPC NOT deleted: it still hosts resources that are not $CLUSTER's (see 'other tenants' above). Re-run with --force-vpc (and --with-data for RDS) only if you are sure."
    exit 1
  fi
  [[ -n "$RDS" ]] && ! $WITH_DATA && { echo "RDS present ($RDS) — VPC deletion needs --with-data"; exit 1; }
  echo; echo "== deleting VPC $VPC =="
  "$HERE/delete-vpc.sh" $($WITH_DATA && echo --with-data) "$VPC"
fi
"$HERE/verify-vpc-deleted.sh" "$VPC" || true
