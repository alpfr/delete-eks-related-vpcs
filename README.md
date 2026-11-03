# delete-eks-vpc

Safe, inventory-first teardown of an Amazon EKS cluster and the VPC that hosted it, using only the AWS CLI, `kubectl`, and `jq`.

Three scripts that build on each other:

| Script | What it does | Destructive? |
|---|---|---|
| `delete-eks.sh <cluster>` | Deletes an EKS cluster the right way round: Kubernetes `LoadBalancer` Services and Ingresses first (so the AWS Load Balancer Controller removes its own ALB/NLB/target groups), then PVCs (EBS/EFS CSI releases the volumes), then node groups → Fargate profiles → add-ons → control plane, then the orphans EKS never cleans up (LBs/TGs tagged for the cluster, `kubernetes.io/cluster/<name>` EBS volumes, `aws-K8S-*` ENIs, the cluster SG, the `/aws/eks/<name>/cluster` log group). With `--with-vpc` it hands the VPC to `delete-vpc.sh` — **only if the VPC hosts nothing foreign**. | Yes (asks for `DESTROY`) |
| `delete-vpc.sh <vpc-id>…` | Inventories and deletes **everything** inside one or more VPCs in dependency order (EKS, ELB/ELBv2 + TGs, EC2 + EBS, NAT GWs + EIPs, endpoints, ENIs, peering, VPN GWs, IGW, subnets, route tables, NACLs, SGs, VPC). Not tag-scoped: anything in the VPC goes. RDS is reported but never deleted without `--with-data`. | Yes (asks for `DESTROY` per VPC) |
| `verify-vpc-deleted.sh <vpc-id>…` | Confirms a VPC is gone and nothing that referenced it is still billing: lists blockers if the VPC still exists (subnets, ENIs with owner descriptions, IGW, NAT, endpoints, SGs, route tables, peering, instances) and checks ELBv2/classic LBs, target groups, EKS, RDS subnet groups, TGW attachments, plus region-wide warnings for unassociated EIPs, unattached EBS and flow-log groups. Exit 0 = clean. `--wait` polls up to 10 min. | No |

Every destructive script has `--dry-run`. **Always run it first and read the inventory** — `delete-vpc.sh` in particular will remove production resources if you point it at the wrong VPC.

## Requirements

- AWS CLI v2, authenticated (profile / SSO / role) with EKS, EC2, ELBv2, ELB, RDS (describe), Logs permissions
- `jq`, `kubectl` (for the Kubernetes-first steps; the script degrades gracefully if the API is unreachable)
- `AWS_REGION` exported (defaults to `us-east-1`)
- Keep the three scripts in the same directory — `delete-eks.sh` calls the other two by relative path

## Quick start

```bash
chmod +x *.sh
export AWS_REGION=us-east-1

# 1. See what would happen
./delete-eks.sh --dry-run my-cluster
./delete-vpc.sh --dry-run vpc-0123456789abcdef0

# 2. Delete the cluster, keep the VPC
./delete-eks.sh my-cluster

# 3. Delete the cluster AND its VPC (refused if the VPC has other tenants)
./delete-eks.sh --with-vpc my-cluster

# 4. Confirm
./verify-vpc-deleted.sh --wait vpc-0123456789abcdef0
```

## Guardrails

- `delete-eks.sh --with-vpc` lists the VPC's *other tenants* — load balancers not tagged `elbv2.k8s.aws/cluster=<name>`, RDS instances, other EKS clusters, EC2 that isn't a node of this cluster — and refuses to touch the VPC if any exist. `--force-vpc` overrides that for load balancers/EC2; RDS additionally requires `--with-data`. There is no flag that deletes RDS without a deliberate choice.
- `delete-vpc.sh` prints the full inventory before asking for confirmation and requires typing `DESTROY` for each VPC separately.
- `verify-vpc-deleted.sh` is read-only and is invoked automatically at the end of both destructive scripts.
- If `delete-vpc` still fails at the final step, re-run `delete-vpc.sh --dry-run` — the usual blockers are ENIs owned by Lambda, EFS mount targets, or Transit Gateway attachments, which must be removed from their own service first.

## Notes

- Clusters created with **eksctl**: prefer `eksctl delete cluster --name <name> --wait`, which also removes its CloudFormation stacks. `delete-eks.sh` works but leaves `eksctl-<name>-*` stacks for you to delete (`aws cloudformation delete-stack`).
- Clusters created with **Terraform**: use `terraform destroy` in that workspace so state stays consistent; use these scripts only when state is lost.
- "cluster not found" from `delete-eks.sh` means the control plane is already gone; what remains is VPC-level debris — go straight to `delete-vpc.sh --dry-run`.

See `DEPLOYMENT.md` for the operational runbook (pre-checks, order, rollback expectations, and what to do when a VPC turns out to be shared).
