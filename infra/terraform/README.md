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

Remote state (S3+DynamoDB) is supported out of the box. The Terraform config contains an empty backend block (`terraform { backend "s3" {} }`) and the backend values are supplied via CLI flags (in CI) or during your local migrate step.

## Structure

- `providers.tf` – AWS provider and default tags
- `versions.tf` – Terraform and providers constraints
- `variables.tf` – Tunable inputs (region, sizes, etc.)
- `network.tf` – VPC, subnets, routing, IGW/NAT via module
- `eks.tf` – EKS cluster + managed node groups (public subnets)
- `outputs.tf` – Useful IDs and endpoints

## Usage (with Remote State)

```bash
cd infra/terraform

# Optionally set your AWS profile
export AWS_PROFILE=your-profile

## One-time local bootstrap (first run only)

Create the remote backend resources using local state, then migrate state to S3:

```bash
cd infra/terraform

# Use local state for the first apply
terraform init -reconfigure -backend=false

# Create only the backend infra (pick unique names/your region)
terraform apply -auto-approve \
  -var 'manage_backend=true' \
  -var 'tf_state_bucket_name=<YOUR_UNIQUE_BUCKET_NAME>' \
  -var 'tf_state_lock_table_name=<YOUR_DYNAMODB_TABLE_NAME>' \
  -target aws_s3_bucket.tf_state \
  -target aws_s3_bucket_versioning.tf_state \
  -target aws_s3_bucket_public_access_block.tf_state \
  -target aws_s3_bucket_server_side_encryption_configuration.tf_state \
  -target aws_dynamodb_table.tf_state_locks

# Migrate local state to S3
terraform init -reconfigure -migrate-state \
  -backend-config="bucket=<YOUR_UNIQUE_BUCKET_NAME>" \
  -backend-config="key=<YOUR_PROJECT_NAME>/infra/terraform.tfstate" \
  -backend-config="region=<YOUR_AWS_REGION>" \
  -backend-config="dynamodb_table=<YOUR_DYNAMODB_TABLE_NAME>" \
  -backend-config="encrypt=true"

# Sanity check pulls state from S3
terraform state pull > /dev/null && echo "Remote state OK"
```

## Normal workflow (after bootstrap)

```bash
cd infra/terraform

# Initialize (uses remote S3 backend)
terraform init -reconfigure \
  -backend-config="bucket=<YOUR_UNIQUE_BUCKET_NAME>" \
  -backend-config="key=<YOUR_PROJECT_NAME>/infra/terraform.tfstate" \
  -backend-config="region=<YOUR_AWS_REGION>" \
  -backend-config="dynamodb_table=<YOUR_DYNAMODB_TABLE_NAME>" \
  -backend-config="encrypt=true"

# Review the plan
terraform plan -out .terraform.plan

# Apply the plan
terraform apply .terraform.plan

# Save kubeconfig and validate the cluster
aws eks update-kubeconfig \
  --region <YOUR_AWS_REGION> \
  --name <YOUR_CLUSTER_NAME> \
  ${AWS_PROFILE:+--profile $AWS_PROFILE}

kubectl get nodes -o wide
```

### CI/CD (GitHub Actions)

Workflows:
- CI: `.github/workflows/terraform-ci.yml`
  - Runs on PRs and pushes (including `main`) that touch `infra/terraform/**`.
  - Performs init/validate/plan.
- CD: `.github/workflows/terraform-cd.yml`
  - Triggers on `workflow_run` of the CI workflow and only proceeds when CI completes successfully for a push to `main`.
  - Checks out the exact commit from the successful CI run and applies the saved plan flow.
  - Application deployments are handled by Terraform via `helm_release` resources in `kubernetes.tf`.

Setup:
- Repo secrets:
  - `AWS_ROLE_ARN`: IAM role ARN trusted for GitHub OIDC.
  - `AWS_REGION`: e.g., `us-east-1`.
  - `TF_STATE_BUCKET`: e.g., `<YOUR_UNIQUE_BUCKET_NAME>` (must already exist from your bootstrap step).
  - `TF_STATE_LOCK_TABLE`: e.g., `<YOUR_DYNAMODB_TABLE_NAME>`.
- Optional: protect the `prod` environment to require approval before apply/deploy.


Notes:
- `providers.tf` contains `terraform { backend "s3" {} }`; backend values are provided via CLI flags in CI and in the commands above.
- The bucket/table are created and optionally managed by this stack behind the `manage_backend` toggle. Use it only for bootstrap to avoid accidental destroys.
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
aws eks update-kubeconfig --region <YOUR_AWS_REGION> --name <YOUR_CLUSTER_NAME> --role-arn "$ROLE_ARN"

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
terraform destroy -var="region=<YOUR_AWS_REGION>" -var="cluster_name=<YOUR_CLUSTER_NAME>"
```

### Admin access for specific IAM principals

If your current IAM identity is different from the cluster creator, you’ll see `You must be logged in to the server (Unauthorized)` after `aws eks update-kubeconfig`.

Grant yourself admin access by applying with your ARN:

```bash
terraform apply -var='admin_principal_arns=["arn:aws:iam::123456789012:user/you"]'

# Then refresh kubeconfig (optionally with --role-arn if you assume a role)
aws eks update-kubeconfig --region <YOUR_AWS_REGION> --name <YOUR_CLUSTER_NAME>
kubectl get nodes
```

This uses EKS Access Entries to bind `AmazonEKSAdminPolicy` at cluster scope to the specified ARNs.
