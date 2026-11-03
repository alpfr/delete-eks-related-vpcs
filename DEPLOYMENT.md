# Deployment & operations runbook — delete-eks-vpc

How to install these scripts on an operator workstation, and the procedure to follow when decommissioning an EKS cluster and its VPC.

## 1. Install

```bash
git clone <repo-url> delete-eks-vpc && cd delete-eks-vpc
chmod +x delete-eks.sh delete-vpc.sh verify-vpc-deleted.sh
aws --version && jq --version && kubectl version --client     # aws cli v2, jq 1.6+, kubectl matching the cluster minor
aws sts get-caller-identity                                  # confirm the account/role you are about to destroy things in
export AWS_REGION=us-east-1
```

The scripts are self-contained Bash; nothing is installed system-wide. Run them from the clone directory (they locate each other via `$(dirname "$0")`).

## 2. Required IAM permissions

Read everywhere; write only on the services being removed. A minimal policy for the operator role:

| Service | Actions |
|---|---|
| EKS | `List*`, `Describe*`, `DeleteNodegroup`, `DeleteFargateProfile`, `DeleteAddon`, `DeleteCluster` |
| EC2 | `Describe*`, `TerminateInstances`, `DeleteVolume`, `DeleteNatGateway`, `ReleaseAddress`, `DeleteVpcEndpoints`, `DeleteNetworkInterface`, `DetachNetworkInterface`, `DeleteVpcPeeringConnection`, `DetachVpnGateway`, `DetachInternetGateway`, `DeleteInternetGateway`, `DeleteSubnet`, `DeleteRouteTable`, `DeleteNetworkAcl`, `RevokeSecurityGroupIngress`, `DeleteSecurityGroup`, `DeleteVpc` |
| ELB / ELBv2 | `Describe*`, `DeleteLoadBalancer`, `DeleteTargetGroup` |
| RDS | `Describe*` (+ `DeleteDBInstance`, `DeleteDBSubnetGroup` only if `--with-data` will ever be used) |
| CloudWatch Logs | `DescribeLogGroups`, `DeleteLogGroup` |
| STS | `GetCallerIdentity` |

Kubernetes access: the caller must be mapped in the cluster's access entries / `aws-auth` with rights to delete Services, Ingresses and PVCs cluster-wide; otherwise `delete-eks.sh` skips the Kubernetes-first step and you must remove the controller-created load balancers by hand afterwards.

## 3. Pre-flight (every time)

1. **Identify ownership.** `aws eks describe-cluster --name <c> --query cluster.resourcesVpcConfig.vpcId` and `aws ec2 describe-vpcs --vpc-ids <vpc> --query 'Vpcs[].Tags'`. Note whether the VPC was created *for* this cluster or is shared.
2. **Dry-run the cluster.** `./delete-eks.sh --dry-run <c>` — read the three blocks: node groups/Fargate/add-ons; Kubernetes LoadBalancer Services, Ingresses, PVCs; and **other tenants of the VPC**. Anything in the last block means `--with-vpc` will be refused, by design.
3. **Dry-run the VPC.** `./delete-vpc.sh --dry-run <vpc>` — read every ENI description. `ELB app/k8s-<ns>-<name>-…` lines identify which application owns each load balancer; `RDSNetworkInterface` means a database lives here.
4. **Backups.** If anything with state is in scope and must survive: RDS manual snapshot (`aws rds create-db-snapshot`), EBS snapshots of PVC volumes you want to keep, and `kubectl get all -A -o yaml > cluster-dump.yaml` for reference.
5. **Change window / sign-off.** Record the dry-run output in the change ticket. The scripts cannot undo anything.

## 4. Procedure

### 4a. Cluster only (VPC is shared or will be reused)

```bash
./delete-eks.sh <cluster>            # type DESTROY
./verify-vpc-deleted.sh <vpc>        # expect: VPC still exists, but no ELBv2/TGs/EKS referencing this cluster
```

Expected duration: 10–20 min (node groups ~5 min each, control plane ~5–10 min).

### 4b. Cluster and its dedicated VPC

```bash
./delete-eks.sh --with-vpc <cluster>    # refuses the VPC step if other tenants exist
./verify-vpc-deleted.sh --wait <vpc>    # exit 0 = clean
```

### 4c. Cluster already gone, VPC left behind ("cluster not found")

```bash
./delete-vpc.sh --dry-run <vpc>         # confirm only debris remains: stale subnets, SG, 'aws-K8S-i-…' ENIs, IGW
./delete-vpc.sh <vpc>
./verify-vpc-deleted.sh <vpc>
aws cloudformation list-stacks --stack-status-filter DELETE_FAILED --query 'StackSummaries[?contains(StackName,`eksctl`)].StackName'   # eksctl leftovers
```

### 4d. VPC turns out to be shared

Do **not** use `--force-vpc`. Decommission application by application from inside the cluster that owns them (`kubectl delete svc/ingress` so the LB controller cleans up), snapshot and delete databases deliberately, remove the NAT gateway last, and only then revisit `delete-vpc.sh --dry-run`. A VPC inventory showing production-looking RDS subnet groups or application-named `k8s-*` load balancers is a stop signal, not a scripting problem.

## 5. Post-run checks

- `verify-vpc-deleted.sh` exit 0 for every VPC touched.
- Region sweep for cost leftovers the scripts only warn about: unassociated EIPs (`aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId'`), unattached EBS (`aws ec2 describe-volumes --filters Name=status,Values=available`), orphan `eksctl-*` CloudFormation stacks, EKS log groups.
- Route 53: records that pointed at deleted load balancers are not removed by these scripts; clean them in the hosted zone.
- IAM: cluster/node roles, OIDC provider (`aws iam list-open-id-connect-providers`), and IRSA roles created for the cluster are left in place — delete when no other cluster uses them.

## 6. Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `delete-eks.sh`: "cannot reach the Kubernetes API" | no access entry / cluster degraded | continue; afterwards delete LBs tagged `elbv2.k8s.aws/cluster=<name>` by hand (the script's orphan sweep catches tagged ones) |
| nodegroup delete hangs | PodDisruptionBudgets block drain | `kubectl delete pdb -A --all` then re-run, or wait for the 15-min EKS force timeout |
| `DependencyViolation` on SG delete | ENI still attached (LB/RDS/Lambda) | `delete-vpc.sh --dry-run` shows the ENI description → remove the owner first |
| `delete-vpc` fails at the final step | Lambda ENI, EFS mount target, TGW attachment, or an un-deleted peering acceptor | remove from the owning service, re-run `delete-vpc.sh` (idempotent) |
| `verify` warns about EIPs/EBS | not necessarily from this VPC | check tags before releasing/deleting |

## 7. Repo hygiene

- Commit only the three `.sh` files, `README.md`, `DEPLOYMENT.md`, `.gitignore`. Never commit dry-run output (contains account IDs/ARNs), `*.zip`, kubeconfigs or `.env` files.
- Tag releases when the deletion order changes; operators should pin a tag in change tickets.
- Test changes against a throw-away cluster/VPC (`eksctl create cluster` in a fresh VPC is the quickest fixture).
