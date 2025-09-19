# Infrastructure as Code (Terraform) for project-bedrock

This Terraform stack provisions:
- An AWS VPC with public and private subnets across multiple AZs
- Internet Gateway and a single NAT Gateway (cost-optimized)
- An Amazon EKS cluster attached to the public subnets (per requirement)
- Managed node group with scaling settings and required IAM policies
- IAM role for developers with read-only EKS access via EKS Access Entries

Note: Running this creates billable AWS resources (EKS, NAT, EC2, etc.). Destroy when done.

## Prerequisites

- Terraform >= 1.5
- AWS credentials configured via one of:
  - `AWS_PROFILE` and `~/.aws/credentials`
  - Environment vars: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally `AWS_SESSION_TOKEN`
- kubectl and awscli for validation

## Structure

- `providers.tf` – AWS provider and default tags
- `versions.tf` – Terraform and providers constraints
- `variables.tf` – Tunable inputs (region, sizes, etc.)
- `network.tf` – VPC, subnets, routing, IGW/NAT via module
- `eks.tf` – EKS cluster + managed node groups (public subnets)
- `outputs.tf` – Useful IDs and endpoints

## Usage

```bash
cd infra/terraform

# Optionally set your AWS profile
export AWS_PROFILE=your-profile

# Initialize modules and providers
terraform init

# Review the plan
terraform plan -out .terraform.plan

# Apply the plan
terraform apply .terraform.plan

# Save kubeconfig and validate the cluster
aws eks update-kubeconfig \
  --region us-east-1 \
  --name bedrock-eks \
  ${AWS_PROFILE:+--profile $AWS_PROFILE}

kubectl get nodes -o wide
```

### CI/CD (GitHub Actions)

Workflows:
- CI: `.github/workflows/terraform-ci.yml`
  - Runs `terraform plan` for PRs and `feature/**` pushes, uploads the plan artifact for review.
- CD: `.github/workflows/terraform-cd.yml`
  - On pushes to `main`, runs `terraform plan -out .tfplan` and applies that saved plan.
  - Application deployments are handled by Terraform via `helm_release` resources in `kubernetes.tf` using values from `deployment/`.

Setup:
- Repo secrets:
  - `AWS_ROLE_ARN`: IAM role ARN trusted for GitHub OIDC.
  - `AWS_REGION`: e.g., `us-east-1`.
- Optional: protect the `prod` environment to require approval before apply/deploy.

Notes:
- For remote state, uncomment the S3 backend in `providers.tf` (and create the bucket + DynamoDB table first).
- Terraform deploys releases: `catalog`, `cart`, `orders`, `ui` in namespace `retail` using `deployment/*.yml`.

### Developer read-only role

This stack creates an IAM role for developers and grants cluster view-only access via EKS Access Entries.

- Role name: `bedrock-developers-eks-readonly` (override with `-var developers_role_name=...`)
- Trust: defaults to this AWS account root. Restrict by passing `-var 'developer_trusted_arns=["arn:aws:iam::123456789012:user/dev1"]'` or role ARNs.
- Permissions: attaches AWS managed `ReadOnlyAccess` (account-wide read-only, includes EKS Describe/List); kubectl permissions are granted via the access policy association `AmazonEKSViewPolicy` at cluster scope.

Assuming the role and using kubectl:

```bash
ROLE_ARN=$(aws iam get-role --role-name bedrock-developers-eks-readonly --query Role.Arn --output text)

# Option A: temporary credentials
aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name dev-view | jq -r '.Credentials | "export AWS_ACCESS_KEY_ID=\(.AccessKeyId)\nexport AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)\nexport AWS_SESSION_TOKEN=\(.SessionToken)"' | bash

# Option B: use --role-arn directly with update-kubeconfig
aws eks update-kubeconfig --region us-east-1 --name bedrock-eks --role-arn "$ROLE_ARN"

kubectl get ns
kubectl get pods -A

helm upgrade --install catalog retail-store-app/src/catalog/chart -n retail --create-namespace -f deployment/catalog.yml
helm upgrade --install cart retail-store-app/src/cart/chart -n retail -f deployment/cart.yml
helm upgrade --install orders retail-store-app/src/orders/chart -n retail -f deployment/orders.yml
helm upgrade --install ui retail-store-app/src/ui/chart -n retail -f deployment/ui.yaml
```

## Configuration

Adjust variables with `-var`, a `*.tfvars` file, or environment variables:

- `region` (default: `us-east-1`)
- `aws_profile` (default: null)
- `cluster_name` (default: `bedrock-eks`)
- `cluster_version` (default: `1.29`)
- `vpc_cidr` (default: `10.0.0.0/16`)
- `az_count` (default: `2`)
- Node group sizing: `node_min_size`, `node_desired_size`, `node_max_size`
- Node instance types: `node_instance_types`

## Notes on IAM and Least Privilege

- EKS module creates the cluster and node group IAM roles with the required AWS-managed policies for EKS and CNI.
- Node groups include `AmazonEC2ContainerRegistryReadOnly` for pulling images; remove if not needed.
- IRSA (IAM Roles for Service Accounts) is enabled (`enable_irsa = true`) for fine-grained pod permissions.
- Developer access is granted via EKS Access Entries with the managed view-only policy. To scope to specific namespaces, change `access_scope` to `type = "namespace"` and set `namespaces`.

## Destroy

```bash
terraform destroy -var="region=us-east-1" -var="cluster_name=bedrock-eks"
```

### Admin access for specific IAM principals

If your current IAM identity is different from the cluster creator, you’ll see `You must be logged in to the server (Unauthorized)` after `aws eks update-kubeconfig`.

Grant yourself admin access by applying with your ARN:

```bash
terraform apply -var='admin_principal_arns=["arn:aws:iam::123456789012:user/you"]'

# Then refresh kubeconfig (optionally with --role-arn if you assume a role)
aws eks update-kubeconfig --region us-east-1 --name bedrock-eks
kubectl get nodes
```

This uses EKS Access Entries to bind `AmazonEKSAdminPolicy` at cluster scope to the specified ARNs.
