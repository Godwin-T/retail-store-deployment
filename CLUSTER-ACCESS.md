Developer Guide: Accessing the EKS Cluster

This guide explains how developers can authenticate and use kubectl to access the Kubernetes cluster created by Terraform under `infra/terraform`.

Scope: This doc covers access only. For architecture details, see `architecture.md`. For Terraform operations, see `infra/terraform/README.md`.

Prerequisites
- AWS CLI v2 installed and configured
- kubectl installed (matching or close to cluster version)
- Optional: AWS SSO or an IAM user/role you can use as a starting identity

Key Facts
- Cluster name default is `bedrock-eks` (set in `infra/terraform/variables.tf:1`).
- Region default is `us-east-1` (set in `infra/terraform/variables.tf:74`).
- A read-only developer IAM role is created by Terraform: `bedrock-developers-eks-readonly` (override via `developers_role_name`). It’s granted EKS view access via EKS Access Entries (see `infra/terraform/iam_developers.tf:18`).
- Optional: specific admins can be granted cluster-admin via `admin_principal_arns` (see `infra/terraform/iam_access_admins.tf:1`).

Set Environment Variables
- Set these once per shell session to make the commands shorter:

```
export AWS_REGION=<YOUR_AWS_REGION>
export CLUSTER_NAME=<YOUR_CLUSTER_NAME>
# If using a named AWS profile (SSO or static keys)
export AWS_PROFILE=<YOUR_AWS_PROFILE>
```

Discover Values (optional helpers)
- Using Terraform outputs (if you can read state):
```
terraform -chdir=infra/terraform output -raw cluster_name
terraform -chdir=infra/terraform output -raw cluster_endpoint
```
- Using AWS CLI (list clusters by region):
```
aws eks list-clusters --region "$AWS_REGION"
```

Access Option A: Use Your Current Identity
- If you’re the cluster creator or you’ve been granted admin/view access directly, you can write kubeconfig with your current identity:

```
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  ${AWS_PROFILE:+--profile "$AWS_PROFILE"}

# Verify
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
```

Access Option B: Assume the Read‑Only Developer Role
- Terraform creates a developer role with EKS view-only permissions. You can access the cluster by referencing the role directly, or by assuming it first.

Method B1 (recommended): reference role in update-kubeconfig
```
ROLE_NAME=bedrock-developers-eks-readonly   # or your custom name
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --role-arn "$ROLE_ARN" \
  ${AWS_PROFILE:+--profile "$AWS_PROFILE"}

kubectl get ns
kubectl get pods -A
```

Method B2: assume role, then run kubectl
```
ROLE_NAME=bedrock-developers-eks-readonly
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name dev-view \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text | awk '{print "export AWS_ACCESS_KEY_ID=" $1 "\nexport AWS_SECRET_ACCESS_KEY=" $2 "\nexport AWS_SESSION_TOKEN=" $3}' | bash

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

kubectl get pods -A
```

Kubeconfig Contexts and Aliases
- `update-kubeconfig` adds/updates a context in `~/.kube/config`. To avoid overwriting or to make a friendly name, use `--alias`:

```
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --alias dev-$CLUSTER_NAME

kubectl config get-contexts
kubectl config use-context dev-$CLUSTER_NAME
```

If You See “Unauthorized”
- You are not bound to the cluster via EKS Access Entries. Ask an operator to:
  - Add your IAM principal to `admin_principal_arns` for admin, or
  - Ensure you can assume the developer view-only role.
- Example (operator action) to grant admin rights:

```
terraform -chdir=infra/terraform apply \
  -var='admin_principal_arns=["arn:aws:iam::123456789012:user/you"]'
```

Verifying Access Level (View‑Only Role)
- The view policy lets you list and get resources but not change them:
```
kubectl get nodes
kubectl get ns
kubectl get pods -A
kubectl auth can-i delete pod -A   # should say no
```

SSO Notes
- If your profile uses AWS SSO, run `aws sso login --profile "$AWS_PROFILE"` first.
- Then use Option A or B; include `--profile "$AWS_PROFILE"` in commands.

Troubleshooting
- Stale local credentials: unset temp vars or re‑assume the role.
- Multiple clusters: use `--alias` and `kubectl config use-context` to switch.
- Region mismatch: confirm `AWS_REGION` and cluster name are correct.
- Missing IAM permissions: ensure your starting identity can call STS `AssumeRole` on the developer role.

Security Notes
- The developer role attaches AWS managed `ReadOnlyAccess` and EKS view policy via Access Entries; it’s safe for day‑to‑day inspection.
- Do not share exported temporary credentials. Prefer the `--role-arn` method or SSO.

