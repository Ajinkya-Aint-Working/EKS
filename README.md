# EKS + Karpenter Terraform Setup 

A two-phase Terraform project that provisions a production-grade Amazon EKS cluster with Karpenter autoscaling and the AWS Load Balancer Controller (ALB Controller). The project is split into two root modules — **Infra** and **Bootstrap** — each with its own remote state, so they can be applied independently and in order.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Phase 1 — Infra Module](#phase-1--infra-module)
   - [VPC & Networking](#vpc--networking)
   - [EKS Cluster](#eks-cluster)
   - [Managed Node Group](#managed-node-group)
   - [EKS Add-ons](#eks-add-ons)
   - [IAM Roles](#iam-roles)
   - [Karpenter IAM & SQS Interruption Queue](#karpenter-iam--sqs-interruption-queue)
   - [ALB Controller IAM](#alb-controller-iam)
   - [Remote State Outputs](#remote-state-outputs)
4. [Phase 2 — Bootstrap Module](#phase-2--bootstrap-module)
   - [Remote State Data Source](#remote-state-data-source)
   - [AWS Load Balancer Controller](#aws-load-balancer-controller)
   - [Karpenter Installation](#karpenter-installation)
   - [Karpenter NodePool & EC2NodeClass](#karpenter-nodepool--ec2nodeclass)
5. [State Backend](#state-backend)
6. [Provider Configuration](#provider-configuration)
7. [Variables Reference](#variables-reference)
8. [Outputs Reference](#outputs-reference)
9. [Deployment Order & Commands](#deployment-order--commands)
10. [Design Decisions & Notes](#design-decisions--notes)
11. [Prerequisites](#prerequisites)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Phase 1: Infra                                         │
│                                                         │
│  VPC (10.0.0.0/16)                                      │
│  ├── Public Subnet AZ-a (10.0.0.0/24)                   │
│  └── Public Subnet AZ-b (10.0.1.0/24)                   │
│                                                         │
│  EKS Cluster (API auth mode)                            │
│  ├── OIDC Provider                                      │
│  ├── Managed Node Group (ON_DEMAND, t3.medium)          │
│  └── Add-ons: vpc-cni, coredns, kube-proxy, ebs-csi     │
│                                                         │
│  IAM Roles                                              │
│  ├── Cluster Role                                       │
│  ├── Node Role                                          │
│  ├── EBS CSI Controller Role (IRSA)                     │
│  ├── ALB Controller Role (IRSA)                         │
│  ├── Karpenter Node Role                                │
│  └── Karpenter Controller Role (IRSA)                   │
│                                                         │
│  SQS + EventBridge (Karpenter Interruption Handling)    │
│  ├── Spot Interruption Warning                          │
│  ├── Instance Rebalance Recommendation                  │
│  ├── Instance State Change                              │
│  └── AWS Health Scheduled Change                        │
└─────────────────────────────────────────────────────────┘
                          │
                  S3 Remote State
                          │
┌─────────────────────────────────────────────────────────┐
│  Phase 2: Bootstrap                                     │
│                                                         │
│  Helm: AWS Load Balancer Controller (kube-system)       │
│  Helm: Karpenter CRDs                                   │
│  Helm: Karpenter Controller (karpenter namespace)       │
│                                                         │
│  kubectl_manifest:                                      │
│  ├── NodePool (default) — spot + on-demand, c/m/r       │
│  └── EC2NodeClass (default) — AL2023, tag discovery     │
└─────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
EKS-Modules/
├── Infra/                          # Phase 1 — AWS infrastructure
│   ├── vpc.tf                      # VPC, subnets, IGW, route tables, security groups
│   ├── eks.tf                      # EKS cluster, OIDC, launch template, node group, add-ons, EBS CSI role
│   ├── iam.tf                      # Cluster role + Node role
│   ├── karpenter_iam.tf            # Karpenter node role, controller role (IRSA), EKS access entry
│   ├── karpenter_sqs.tf            # SQS interruption queue + 4 EventBridge rules
│   ├── alb_iam.tf                  # ALB controller IAM policy + role (IRSA)
│   ├── outputs.tf                  # All outputs consumed by Bootstrap via remote state
│   ├── variables.tf                # Input variables with sensible defaults
│   ├── provider.tf                 # AWS, Kubernetes, Helm, kubectl providers
│   ├── versions.tf                 # Terraform + provider version pins
│   ├── backend.tf                  # S3 backend (key: Infra/terraform.tfstate)
│   └── policies/
│       ├── alb_iam_policy.json     # Full ALB controller IAM policy document
│       └── karpenter-controller-policy.json  # Karpenter controller policy (templatefile)
│
└── Bootstrap/                      # Phase 2 — Kubernetes-level bootstrapping
    ├── alb.tf                      # Service account + Helm release for ALB controller
    ├── karpenter_install.tf        # Namespace + Helm releases for Karpenter CRDs and controller
    ├── karpenter_nodepool.tf       # NodePool and EC2NodeClass kubectl_manifests
    ├── data.tf                     # terraform_remote_state from Infra + locals
    ├── output.tf                   # Karpenter Helm release status
    ├── variables.tf                # region, karpenter_version, karpenter_namespace
    ├── provider.tf                 # AWS, Kubernetes, Helm, kubectl (exec-based auth)
    ├── versions.tf                 # Terraform + provider version pins
    └── backend.tf                  # S3 backend (key: Bootstrap/terraform.tfstate)
```

---

## Phase 1 — Infra Module

### VPC & Networking

**File:** `Infra/vpc.tf`

A fresh VPC is created with DNS hostnames enabled. The number of public subnets is controlled by `var.public_subnet_count` (default: 2). Each subnet gets a dynamically computed `/24` CIDR block carved out of `var.vpc_cidr` (`10.0.0.0/16`) using `cidrsubnet()`, placed in successive availability zones.

**Subnet tags are critical** — three tag sets are applied:

| Tag | Value | Purpose |
|-----|-------|---------|
| `kubernetes.io/role/elb` | `1` | Tells the ALB controller these subnets are eligible for internet-facing ALBs |
| `kubernetes.io/cluster/<name>` | `owned` | EKS subnet ownership |
| `karpenter.sh/discovery` | `<cluster-name>` | Karpenter subnet discovery via tag selector |

A single public route table routes `0.0.0.0/0` through the Internet Gateway and is associated with all public subnets.

**Security Groups** follow an important pattern: ingress rules are defined as **separate `aws_security_group_rule` resources** (not inline blocks). This avoids Terraform conflicts when EKS also manages ingress rules. The `lifecycle { ignore_changes = [ingress] }` block is set on both security groups to prevent Terraform from fighting EKS's own rule management.

The following ingress rules are created:

| Rule | From | To | Description |
|------|------|----|-------------|
| `cluster_to_node` | EKS Cluster SG | Node SG | All traffic, control plane → workers |
| `node_to_cluster` | Node SG | EKS Cluster SG | All traffic, workers → control plane |
| `node_to_node` | Node SG (self) | Node SG | Pod-to-pod and node-to-node |
| `cluster_api_access` | `0.0.0.0/0` | EKS Cluster SG (443) | Public kubectl / API access |
| `alb_to_node` | VPC CIDR | Node SG (all TCP ports) | ALB → NodePort services |

The Node SG is also tagged with `karpenter.sh/discovery: <cluster-name>` so Karpenter can discover it for new nodes.

---

### EKS Cluster

**File:** `Infra/eks.tf`

The cluster is created with:

- **Authentication mode: `API`** — this is the modern access entry model. No `aws-auth` ConfigMap is needed; access is managed via `aws_eks_access_entry` resources instead.
- **`bootstrap_cluster_creator_admin_permissions: true`** — the IAM identity running `terraform apply` is automatically granted cluster admin access.
- **Public endpoint only** (`endpoint_public_access = true`, `endpoint_private_access = false`) — suitable for development; tighten for production.
- **OIDC Provider** — created from the cluster's OIDC issuer URL and the TLS thumbprint fetched live. This is the prerequisite for all IRSA (IAM Roles for Service Accounts) roles.

---

### Managed Node Group

**File:** `Infra/eks.tf`

A single **ON_DEMAND** managed node group serves as the "system" node group — it hosts the Karpenter and ALB controller pods before Karpenter has provisioned any worker nodes.

The Launch Template enforces:
- IMDSv2 required (`http_tokens = required`) — security hardening
- 20 GB encrypted `gp3` EBS root volume
- Detailed resource tagging (instance, volume, ENI) for cost attribution and Kubernetes ownership

Scaling is controlled by `var.desired_size` / `var.min_size` / `var.max_size` (defaults: 2/1/3).

The node group is labeled `type: ondemand` so Karpenter's affinity rules can pin itself to these nodes.

---

### EKS Add-ons

**File:** `Infra/eks.tf`

Four managed add-ons are installed via `aws_eks_addon`, driven by a `var.addons` list variable (easy to extend):

| Add-on | Default Version | Notes |
|--------|----------------|-------|
| `vpc-cni` | v1.21.1-eksbuild.1 | AWS pod networking |
| `coredns` | v1.13.2-eksbuild.3 | Cluster DNS |
| `kube-proxy` | v1.35.0-eksbuild.2 | Network rules |
| `aws-ebs-csi-driver` | v1.57.1-eksbuild.1 | PersistentVolume support; gets its own IRSA role |

The EBS CSI driver add-on is special — it requires an IRSA role (`ebs-csi-controller-role`) that allows `sts:AssumeRoleWithWebIdentity` for the `ebs-csi-controller-sa` service account in `kube-system`. The managed policy `AmazonEBSCSIDriverPolicy` is attached. All other add-ons receive no `service_account_role_arn`.

---

### IAM Roles

**File:** `Infra/iam.tf`

Two foundational roles:

**EKS Cluster Role** (`<cluster-name>-cluster-role`): Trusted by `eks.amazonaws.com`. Policy: `AmazonEKSClusterPolicy`.

**Node Role** (`<cluster-name>-node-role`): Trusted by `ec2.amazonaws.com`. Policies (applied with `for_each` over a set):
- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonEKS_CNI_Policy`
- `AmazonSSMManagedInstanceCore` (enables SSM Session Manager access to nodes)

---

### Karpenter IAM & SQS Interruption Queue

**Files:** `Infra/karpenter_iam.tf`, `Infra/karpenter_sqs.tf`

Karpenter requires two separate IAM roles — one for the nodes it launches, one for its own controller pod.

**Karpenter Node Role** (`KarpenterNodeRole-<cluster-name>`): Trusted by `ec2.amazonaws.com`. Policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryPullOnly`
- `AmazonSSMManagedInstanceCore`

Since the cluster uses `authentication_mode = API`, a **`aws_eks_access_entry`** resource of type `EC2_LINUX` is created for this role — this registers it as a trusted node identity without touching `aws-auth`.

**Karpenter Controller Role** (`KarpenterControllerRole-<cluster-name>`): IRSA role trusted by the OIDC provider. The trust policy uses `StringEquals` conditions on both `:aud` (`sts.amazonaws.com`) and `:sub` (`system:serviceaccount:karpenter:karpenter`). The inline policy is rendered from `policies/karpenter-controller-policy.json` using `templatefile()` with four substitutions:

| Template Variable | Value |
|------------------|-------|
| `${cluster_name}` | Cluster name |
| `${region}` | AWS region |
| `${karpenter_node_role_arn}` | Node role ARN (for `iam:PassRole`) |
| `${eks_cluster_arn}` | Cluster ARN (for `eks:DescribeCluster`) |
| `${sqs_queue_arn}` | SQS queue ARN |

The policy grants Karpenter the ability to launch instances, create/delete launch templates, manage instance profiles (scoped to Karpenter-owned profiles via tag conditions), terminate instances tagged with `karpenter.sh/nodepool`, and interact with the SQS interruption queue.

**SQS Interruption Queue** (`<cluster-name>-karpenter-spot-events`): Receives events from four EventBridge rules so Karpenter can gracefully handle node interruptions before AWS reclaims them:

| EventBridge Rule | Event Source | Use Case |
|-----------------|-------------|----------|
| `spot_interruption` | `aws.ec2` — Spot Interruption Warning | 2-minute warning before Spot reclaim |
| `rebalance_recommendation` | `aws.ec2` — Rebalance Recommendation | Early replacement of at-risk Spot nodes |
| `instance_state_change` | `aws.ec2` — State-change Notification | Catch unexpected terminations |
| `scheduled_change` | `aws.health` — AWS Health Event | AWS maintenance window notifications |

The SQS queue policy allows `events.amazonaws.com` to `sqs:SendMessage` only from the ARNs of these four rules (using `aws:SourceArn` condition). SSE is enabled with SQS-managed keys. Message retention is 14 days; visibility timeout is 5 minutes.

---

### ALB Controller IAM

**File:** `Infra/alb_iam.tf`

The ALB Controller requires a comprehensive IAM policy (loaded from `policies/alb_iam_policy.json`) covering EC2 describe actions, ELBv2 CRUD operations, security group management, WAF/Shield integration, ACM certificate lookups, and Cognito. The policy file is the official AWS-provided policy for the controller.

An IRSA role (`alb-controller-role`) is created with a trust policy scoped to `system:serviceaccount:kube-system:aws-load-balancer-controller`.

---

### Remote State Outputs

**File:** `Infra/outputs.tf`

Everything the Bootstrap module needs is exported as outputs and stored in the Infra S3 state key. Key outputs include:

- `cluster_name`, `cluster_endpoint`, `cluster_ca` (sensitive)
- `vpc_id`, `public_subnets`
- `node_group_name` (used to pin Karpenter pods via node affinity)
- `alb_controller_role_arn`
- `karpenter_controller_role_arn`, `karpenter_node_role_arn`
- `karpenter_sqs_queue_name`, `karpenter_sqs_queue_url`, `karpenter_sqs_queue_arn`
- `oidc_provider_arn`, `cluster_oidc_issuer_url`

---

## Phase 2 — Bootstrap Module

### Remote State Data Source

**File:** `Bootstrap/data.tf`

The Bootstrap module has zero hardcoded values. All infrastructure references are pulled from the Infra module's remote state:

```hcl
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "terraform-s3-state-007"
    key    = "Infra/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

All values are aliased to locals for clean usage throughout the module (`local.cluster_name`, `local.vpc_id`, etc.).

---

### AWS Load Balancer Controller

**File:** `Bootstrap/alb.tf`

Two resources are created:

1. **`kubernetes_service_account_v1.alb`** in `kube-system` — annotated with `eks.amazonaws.com/role-arn` pointing to the ALB controller IRSA role. Creating the service account before the Helm release and disabling Helm's own SA creation prevents a double-create conflict.

2. **`helm_release.alb`** from `https://aws.github.io/eks-charts` — key chart values set:
   - `clusterName` — EKS cluster name
   - `serviceAccount.create = false` — use the pre-created SA
   - `serviceAccount.name` — name of the SA above
   - `vpcId` — required for IP target type ALBs
   - `region` — AWS region

   `cleanup_on_fail = true` and `wait = true` with a 600-second timeout ensure idempotent installs.

---

### Karpenter Installation

**File:** `Bootstrap/karpenter_install.tf`

Three resources, applied in this order:

1. **`kubernetes_namespace_v1.karpenter`** — creates the `karpenter` namespace (controlled by `var.karpenter_namespace`, default `karpenter`).

2. **`helm_release.karpenter_crds`** — installs the `karpenter-crd` chart from `oci://public.ecr.aws/karpenter`. CRDs are installed as a **separate Helm release** from the controller — this is intentional. If both are in the same release, a Helm upgrade that changes a CRD can fail because Helm tries to replace immutable CRD fields. Separating them gives lifecycle independence.

3. **`helm_release.karpenter`** — installs the `karpenter` chart with:
   - `settings.clusterName` — cluster name
   - `settings.interruptionQueue` — SQS queue name for interruption handling
   - `serviceAccount.annotations` — IRSA annotation with the controller role ARN
   - CPU/memory requests and limits set to `1 CPU / 1Gi` each
   - **Node Affinity** — pins Karpenter pods to the existing managed node group using the `eks.amazonaws.com/nodegroup` label. This prevents a chicken-and-egg problem where Karpenter would need to schedule itself but no Karpenter nodes exist yet.

   The `depends_on` chain: `karpenter_crds` → `alb` ensures ALB is ready before CRDs, and CRDs before the controller.

---

### Karpenter NodePool & EC2NodeClass

**File:** `Bootstrap/karpenter_nodepool.tf`

Two `kubectl_manifest` resources apply Karpenter's CRD instances as inline YAML:

**`NodePool` (default):**

| Field | Value | Meaning |
|-------|-------|---------|
| `kubernetes.io/arch` | `amd64` | x86 nodes only |
| `kubernetes.io/os` | `linux` | Linux only |
| `karpenter.sh/capacity-type` | `spot, on-demand` | Both capacity types allowed |
| `karpenter.k8s.aws/instance-category` | `c, m, r` | Compute, Memory, Memory-optimized families |
| `karpenter.k8s.aws/instance-generation` | `> 3` | Only 4th gen and newer |
| `expireAfter` | `720h` (30 days) | Nodes are replaced after 30 days (drift/security patching) |
| `limits.cpu` | `1000` | Hard cap: cluster will not scale beyond 1000 vCPUs via Karpenter |
| `consolidationPolicy` | `WhenEmptyOrUnderutilized` | Aggressive cost optimization |
| `consolidateAfter` | `1m` | Consolidation check interval |

**`EC2NodeClass` (default):**

| Field | Value | Meaning |
|-------|-------|---------|
| `role` | `KarpenterNodeRole-<cluster-name>` | IAM role for launched instances |
| `amiSelectorTerms` | `al2023@latest` | Always use latest Amazon Linux 2023 AMI |
| `subnetSelectorTerms` | tag: `karpenter.sh/discovery: <cluster-name>` | Discovers subnets by tag |
| `securityGroupSelectorTerms` | tag: `karpenter.sh/discovery: <cluster-name>` | Discovers SGs by tag |

Both resources `depends_on = [helm_release.karpenter]` to ensure the CRDs exist before applying.

---

## State Backend

Both modules use S3 as the Terraform backend with **native S3 locking** (`use_lockfile = true`, available in Terraform ≥ 1.10):

| Module | S3 Key |
|--------|--------|
| Infra | `Infra/terraform.tfstate` |
| Bootstrap | `Bootstrap/terraform.tfstate` |

Both share the same bucket (`terraform-s3-state-007`) in `ap-south-1` with encryption enabled. No DynamoDB lock table is required.

---

## Provider Configuration

Both modules use four providers:

| Provider | Source | Version |
|----------|--------|---------|
| `aws` | `hashicorp/aws` | 6.38.0 |
| `kubernetes` | `hashicorp/kubernetes` | 3.0.1 |
| `helm` | `hashicorp/helm` | 3.1.1 |
| `kubectl` | `gavinbunney/kubectl` | 1.19.0 |

**Infra** authenticates the Kubernetes/Helm/kubectl providers via a static token from `data.aws_eks_cluster_auth` — this works during initial provisioning because Infra creates the cluster and immediately reads it back.

**Bootstrap** uses the `exec` approach (`aws eks get-token`) for Kubernetes/Helm/kubectl authentication. This fetches a fresh short-lived token at plan/apply time and is the recommended pattern for CI/CD pipelines.

---

## Variables Reference

### Infra Variables (`Infra/variables.tf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `ap-south-1` | AWS region |
| `cluster_name` | `demo` | EKS cluster name (used as prefix for all resources) |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `cluster_version` | `1.35` | EKS Kubernetes version |
| `instance_type` | `t3.medium` | Node group instance type |
| `desired_size` | `2` | Node group desired count |
| `max_size` | `3` | Node group max count |
| `min_size` | `1` | Node group min count |
| `public_subnet_count` | `2` | Number of public subnets (and AZs) |
| `addons` | (see below) | List of EKS managed add-ons |
| `tags` | `{Environment=dev, Terraform=true}` | Default tags applied to all resources |
| `karpenter_namespace` | `karpenter` | Namespace for Karpenter (used in IRSA trust condition) |

### Bootstrap Variables (`Bootstrap/variables.tf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `ap-south-1` | AWS region |
| `karpenter_version` | `1.11.0` | Karpenter Helm chart version (used for both controller and CRD charts) |
| `karpenter_namespace` | `karpenter` | Kubernetes namespace for Karpenter |

---

## Outputs Reference

### Infra Outputs

| Output | Sensitive | Description |
|--------|-----------|-------------|
| `cluster_name` | No | EKS cluster name |
| `cluster_endpoint` | No | EKS API server endpoint |
| `cluster_version` | No | Kubernetes version |
| `cluster_oidc_issuer_url` | No | OIDC issuer URL |
| `cluster_ca` | **Yes** | Base64 cluster CA certificate |
| `kubectl_config` | No | Map with cluster_name and region for kubeconfig |
| `node_group_name` | No | Managed node group name |
| `node_group_status` | No | Node group status |
| `vpc_id` | No | VPC ID |
| `public_subnets` | No | List of public subnet IDs |
| `internet_gateway_id` | No | IGW ID |
| `eks_cluster_sg` | No | EKS cluster security group ID |
| `node_sg` | No | Node security group ID |
| `eks_cluster_role_arn` | No | EKS cluster IAM role ARN |
| `node_role_arn` | No | Node IAM role ARN |
| `oidc_provider_arn` | No | OIDC provider ARN |
| `alb_controller_role_arn` | No | ALB controller IRSA role ARN |
| `karpenter_node_role_arn` | No | Karpenter node IAM role ARN |
| `karpenter_controller_role_arn` | No | Karpenter controller IRSA role ARN |
| `karpenter_sqs_queue_url` | No | Interruption queue URL |
| `karpenter_sqs_queue_arn` | No | Interruption queue ARN |
| `karpenter_sqs_queue_name` | No | Interruption queue name |

### Bootstrap Outputs

| Output | Description |
|--------|-------------|
| `karpenter_status` | Helm release status of the Karpenter chart |

---

## Deployment Order & Commands

### Prerequisites

```bash
# Confirm AWS credentials
aws sts get-caller-identity

# Confirm Terraform version (>= 1.11.0 required for use_lockfile)
terraform version

# Ensure the S3 state bucket exists
aws s3 ls s3://terraform-s3-state-007
```

### Step 1 — Apply Infra

```bash
cd Infra/

terraform init
terraform plan -out=infra.tfplan
terraform apply infra.tfplan
```

Approximate apply time: 15–20 minutes (EKS cluster creation dominates).

### Step 2 — Update kubeconfig

```bash
aws eks update-kubeconfig \
  --name demo \
  --region ap-south-1

kubectl get nodes
```

### Step 3 — Apply Bootstrap

```bash
cd ../Bootstrap/

terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Approximate apply time: 5–8 minutes (Helm releases with `wait = true`).

### Step 4 — Verify

```bash
# Check ALB controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check Karpenter
kubectl get pods -n karpenter

# Check NodePool and EC2NodeClass
kubectl get nodepools
kubectl get ec2nodeclasses

# Verify Karpenter is pinned to the managed node group
kubectl get pods -n karpenter -o wide
```

### Teardown

```bash
# Destroy in reverse order — Bootstrap first, then Infra
cd Bootstrap/
terraform destroy

cd ../Infra/
terraform destroy
```

> **Note:** Destroy may fail if Karpenter-provisioned nodes or ALB-managed load balancers exist. Scale down workloads and manually delete ALBs/target groups before running `terraform destroy` on Infra if needed.

---

## Design Decisions & Notes

**Two-module split vs. one module:**
Infra and Bootstrap are deliberately separate because Bootstrap requires a running EKS cluster with a reachable API server. Trying to apply both in a single `terraform apply` causes provider initialization failures since the Kubernetes/Helm providers cannot connect to a cluster that doesn't exist yet.

**API auth mode (no aws-auth ConfigMap):**
The cluster uses `authentication_mode = API` which is the current AWS recommended approach. Node access is granted via `aws_eks_access_entry` resources (type `EC2_LINUX`), eliminating the fragile aws-auth ConfigMap pattern.

**Karpenter pinned to managed node group:**
The node affinity in the Karpenter Helm release ensures Karpenter's own pods run on the stable managed node group — not on nodes Karpenter itself manages. This avoids a race condition on startup and on disruption events.

**Karpenter CRDs as a separate Helm release:**
Installing `karpenter-crd` separately from `karpenter` allows upgrading CRDs independently of the controller, avoiding Helm's inability to safely update CRDs in the same release as the controller.

**Security group rules as separate resources:**
Using `aws_security_group_rule` resources (instead of inline `ingress` blocks) with `lifecycle { ignore_changes = [ingress] }` prevents Terraform from fighting EKS's own dynamic security group rule management during node registration.

**Spot interruption handling:**
The four EventBridge → SQS rules give Karpenter advance notice of node loss events. Karpenter uses this queue to cordon and drain nodes gracefully before AWS terminates them, preventing pod disruption.

**IMDSv2 enforced:**
The launch template sets `http_tokens = required`, enforcing IMDSv2 on all managed nodes. Karpenter-launched nodes inherit this via the EC2NodeClass.

**`expireAfter: 720h` on NodePool:**
Nodes are voluntarily replaced every 30 days. This ensures OS patches and AMI updates are applied without requiring manual intervention, since the EC2NodeClass uses `al2023@latest`.

---

## Prerequisites

- Terraform >= 1.11.0
- AWS CLI >= 2.x, authenticated with sufficient IAM permissions
- S3 bucket `terraform-s3-state-007` pre-created in `ap-south-1` with versioning enabled
- `kubectl` installed locally
- `helm` is not required locally (Terraform's Helm provider handles all chart operations)