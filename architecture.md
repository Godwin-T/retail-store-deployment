# Project Architecture (infra/terraform)

This document explains the infrastructure architecture defined in `infra/terraform`. It covers why each part exists, what it does, and which technologies/modules are used, so a new contributor can understand, operate, and extend the stack.

## Goals (Why)

- Reproducible, codified AWS environment for a retail microservices demo on Kubernetes (EKS).
- Keep cost reasonable while remaining realistic: single NAT gateway, one managed node group, public cluster endpoint, small instance sizes.
- Demonstrate polyglot persistence and messaging patterns with managed AWS services (Aurora MySQL/Postgres, DynamoDB, Amazon MQ/RabbitMQ, ElastiCache/Redis).
- Provide safe access patterns: least-privilege pod access (IRSA), read‑only developer role, and optional admin bindings via EKS Access Entries.
- Use upstream, well‑maintained Terraform modules and providers for reliability and faster iteration.

## High‑Level Overview (What)

- Network: VPC with public and private subnets across multiple AZs, NAT for private egress.
- Compute: Amazon EKS cluster with one managed node group, public API endpoint, IRSA enabled.
- Cluster add‑ons: AWS Load Balancer Controller and cert‑manager via Blueprints Addons.
- Data stores:
  - Catalog: Aurora MySQL in private subnets.
  - Orders: Aurora Postgres in private subnets.
  - Carts: DynamoDB table with a GSI.
  - Checkout cache: ElastiCache Redis in private subnets (provisioned; no app defined here uses it yet).
- Messaging: Amazon MQ (RabbitMQ) broker in private subnets for the Orders service.
- Kubernetes workloads (deployed via Terraform provider): namespace `retail`; services: `catalog`, `carts`, `orders`, and `ui` with `ClusterIP` Services.
- Access & IAM: developer read‑only role, optional cluster‑admin bindings for specific principals, IRSA role for carts to access DynamoDB.
- State: remote state backend (S3 + DynamoDB) supported and optionally bootstrapped.

## Plain‑English Deep Dive

Think of this as setting up a small, private neighborhood for an online store, plus a factory where the store’s software runs.

- The private neighborhood (Network)
  - We create a private area in AWS called a VPC. Inside it are “public streets” (public subnets) and “private streets” (private subnets). Computers on private streets cannot be reached directly from the internet.
  - A single “gateway” (NAT) lets computers on private streets go out to the internet for updates, but outsiders can’t come in. This keeps costs lower while staying realistic for a demo.

- The factory (Kubernetes on EKS)
  - EKS is the managed Kubernetes service. It’s where our apps run. We add a small group of worker machines (a managed node group) that actually do the work.
  - For simplicity, the factory’s front door (the cluster API) is reachable from the internet so operators can manage it. In a locked‑down production setup you’d flip this so it’s private.

- Helpful equipment (Add‑ons)
  - Load Balancer Controller: helps create AWS load balancers if/when we expose apps to the internet.
  - cert‑manager: helps automate TLS certificates if you later add HTTPS endpoints.

- The data stores (where information lives)
  - Catalog (products): lives in an Aurora MySQL database on the private streets.
  - Orders: lives in an Aurora Postgres database on the private streets.
  - Shopping carts: live in DynamoDB (a serverless NoSQL database) — fast, simple, scales automatically.
  - Cache: a small Redis cache (ElastiCache) on the private streets, ready for checkout‑related speedups.

- The postal service (Messaging)
  - We run a managed RabbitMQ broker (Amazon MQ). The Orders service can use it to send/receive messages reliably. It sits on the private streets and only accepts mail from the factory workers.

- The store apps (what customers and services use)
  - UI: the storefront website.
  - Catalog: provides product data to the UI.
  - Carts: stores each shopper’s cart in DynamoDB.
  - Orders: places orders, talking to Postgres and RabbitMQ.
  - These apps talk to each other over the neighborhood’s internal network. They are not exposed to the internet yet — that keeps the demo safe. To make it public, you’d add an “Ingress” (a front door) later.

- Who can access what (Identity & permissions)
  - A read‑only developer role lets team members safely look around the cluster without changing things.
  - An optional admin binding can grant full control to specific people/roles when needed.
  - For the Carts app, we use a safe pattern (IRSA) so only that app gets limited, temporary permission to read/write its DynamoDB table — not a broad, permanent key.

- How deployment happens (in plain steps)
  1) Build the neighborhood (VPC and subnets). 2) Stand up the factory (EKS) and its workers. 3) Install helpful equipment (add‑ons). 4) Create the databases, message broker, and cache on private streets. 5) Deploy the four apps into a `retail` namespace and connect them to their data. 6) Everything is wired to talk internally; you can later add a public front door if you want to open the shop to the world.

- What this costs (conceptually)
  - You pay for the EKS control plane, worker machines, the NAT gateway, the databases, the message broker, and the cache while they are running. This demo keeps sizes small and uses one NAT to reduce cost. Always destroy the stack when you’re done.

- How to make it public later
  - Add an “Ingress” for the UI and the Load Balancer Controller will provision an AWS load balancer. Point your domain name there and add TLS via cert‑manager. Until you do this, the apps are internal‑only.

- Common terms translated
  - VPC: a fenced‑off private network in AWS.
  - Subnet (public/private): segments of that network, public can be reached from the internet, private cannot.
  - NAT gateway: lets private resources reach out to the internet without exposing them to inbound traffic.
  - EKS/Kubernetes: a platform to run containers (small packaged apps) reliably.
  - IRSA: a safe way to give a specific app limited AWS permissions without long‑lived keys.
  - Aurora: a managed, high‑performance relational database (MySQL/Postgres flavors).
  - DynamoDB: a serverless NoSQL database that scales automatically.
  - ElastiCache (Redis): a very fast, in‑memory data store for caching.
  - RabbitMQ: a message queue that helps services talk to each other reliably.
  - ConfigMap/Secret: app settings and passwords given to containers at runtime.
  - Deployment/Service: how we run an app and how it’s reachable inside the cluster.


## Technology & Modules (How)

- Providers and versions
  - AWS provider `~> 5.0` (providers: `infra/terraform/versions.tf:1`).
  - Kubernetes and Helm providers configured to authenticate to the created EKS cluster using cluster token (`infra/terraform/providers.tf:18`, `infra/terraform/providers.tf:30`).
  - Additional providers used implicitly by resources: `random`, `time`.
- Core modules
  - VPC: `terraform-aws-modules/vpc/aws ~> 5.0` (`infra/terraform/vpc.tf:12`).
  - EKS: `terraform-aws-modules/eks/aws ~> 20.0` (`infra/terraform/eks.tf:1`).
  - EKS Addons: `aws-ia/eks-blueprints-addons/aws ~> 1.0` (`infra/terraform/eks.tf:76`).
  - Aurora (MySQL/Postgres): `terraform-aws-modules/rds-aurora/aws 7.7.1` (`infra/terraform/dependencies_v2.tf:18`, `infra/terraform/dependencies_v2.tf:56`).
  - DynamoDB table: `terraform-aws-modules/dynamodb-table/aws 3.3.0` (`infra/terraform/dependencies_v2.tf:94`).
  - ElastiCache Redis: `cloudposse/elasticache-redis/aws 0.53.0` (`infra/terraform/dependencies_v2.tf:177`).

## Network

- VPC across `var.az_count` AZs with DNS hostnames/support enabled; subnets are CIDR‑derived and tagged for Kubernetes load balancers (`infra/terraform/vpc.tf:1`).
- Public subnets are used for the EKS cluster and its node group (intentional, per requirement) (`infra/terraform/eks.tf:28`).
 - One NAT Gateway for cost control; private subnets host stateful services (Aurora, MQ, Redis) while allowing egress via NAT (`infra/terraform/vpc.tf:22`).

## EKS Cluster & Add‑ons

- Cluster
  - Module: `terraform-aws-modules/eks` with `enable_irsa = true` for fine‑grained pod IAM (`infra/terraform/eks.tf:41`).
  - Public endpoint enabled; private endpoint disabled (simple access) (`infra/terraform/eks.tf:11`).
  - Managed node group with small instances and modest autoscaling defaults; ECR read‑only policy attached for image pulls (`infra/terraform/eks.tf:49`).
  - Node security group rules allow intra‑node traffic and DNS; optional Istio control‑plane ports guarded by toggle `var.istio_enabled` (`infra/terraform/eks.tf:55`).
- Add‑ons
  - AWS Load Balancer Controller and cert‑manager via Blueprints Addons (`infra/terraform/eks.tf:76`).
  - A brief `time_sleep` ensures add‑on readiness before dependent resources (`infra/terraform/eks.tf:106`).

Notes:
- No Ingress resources are defined in Terraform here; Services are `ClusterIP`. To expose apps externally, add Kubernetes `Ingress` + ALB annotations.

## Data, Messaging, and Caching

- Catalog DB: Aurora MySQL cluster in private subnets; encrypted; admin password generated via `random_string`; EKS node SG allowed for connectivity (`infra/terraform/dependencies_v2.tf:18`).
- Orders DB: Aurora Postgres cluster in private subnets; encrypted; admin password generated via `random_string`; EKS node SG allowed (`infra/terraform/dependencies_v2.tf:56`).
- Carts DB: DynamoDB table with primary key `id` and GSI on `customerId`; dedicated IAM policy granting full table access (`infra/terraform/dependencies_v2.tf:94`).
- Orders Queue: Amazon MQ (RabbitMQ) single‑instance broker in a private subnet; access restricted via a Security Group that allows traffic only from the EKS node SG on 5671/TCP; password generated via `random_password` (`infra/terraform/dependencies_v2.tf:126`).
- Checkout Cache: ElastiCache Redis (cluster/single‑node) in private subnets; allowed from EKS node SG (`infra/terraform/dependencies_v2.tf:177`).

## IAM and Access Control

- IRSA for Carts
  - Dedicated IAM role assumed via OIDC by the `carts-sa` service account in namespace `retail` (`infra/terraform/iam_irsa_cart.tf:1`).
  - Role gets the DynamoDB access policy defined for the carts table (`infra/terraform/dependencies_v2.tf:126`, `infra/terraform/iam_irsa_cart.tf:38`).
- Developer Role (read‑only)
  - IAM role (`var.developers_role_name`) trusted by configurable principals; has AWS `ReadOnlyAccess` and is granted `AmazonEKSViewPolicy` at cluster scope via EKS Access Entries (`infra/terraform/iam_developers.tf:18`).
- Admin Access (optional)
  - Principals listed in `var.admin_principal_arns` receive `AmazonEKSAdminPolicy` at cluster scope using EKS Access Entries (`infra/terraform/iam_access_admins.tf:1`).

## Kubernetes Workloads (via Terraform)

 - Provider wiring: After the EKS cluster exists, Terraform reads its endpoint/CA and auth token, then configures the Kubernetes and Helm providers against it (`infra/terraform/providers.tf:20`).
 - Namespace: All demo services live in `retail` (`infra/terraform/kubernetes_v2.tf:20`).
- Catalog
  - ConfigMap wiring for Aurora MySQL endpoint/port/name; Secret for credentials; ExternalName Service pointing to the Aurora endpoint; `Deployment` uses image `public.ecr.aws/aws-containers/retail-store-sample-catalog:1.3.0` and exposes `ClusterIP` Service on port 80 (`infra/terraform/kubernetes_v2.tf:33`).
- Carts
  - `ServiceAccount` annotated with the IRSA role; ConfigMap sets DynamoDB table and disables table creation; `Deployment` uses `public.ecr.aws/aws-containers/retail-store-sample-cart:1.3.0`; `ClusterIP` Service on port 80 (`infra/terraform/kubernetes_v2.tf:222`, `infra/terraform/kubernetes_v2.tf:241`).
- Orders
  - ConfigMap wires RabbitMQ endpoint and Aurora Postgres endpoint/name; Secret for DB credentials; `Deployment` uses `public.ecr.aws/aws-containers/retail-store-sample-orders:1.3.0`; `ClusterIP` Service on port 80 (`infra/terraform/kubernetes_v2.tf:365`).
- UI
  - ConfigMap points to internal service DNS for the three backends; `Deployment` uses `public.ecr.aws/aws-containers/retail-store-sample-ui:1.3.0`; `ClusterIP` Service on port 80 (`infra/terraform/kubernetes_v2.tf:549`).

Traffic flow
- Browser → [Ingress/ALB to be added] → `ui` Service → internal `catalog`/`carts`/`orders` Services.
- `catalog` → Aurora MySQL (private).
- `carts` → DynamoDB via IRSA.
- `orders` → Aurora Postgres + RabbitMQ (private).

## State Management

- Remote state backend is S3 with DynamoDB locking. The backend stanza is intentionally empty and is configured via CLI/automation (`infra/terraform/providers.tf:13`).
- Optional bootstrap creates the S3 bucket and DynamoDB lock table behind the `manage_backend` toggle (`infra/terraform/tf_backend_resources.tf:1`).

## Security Posture & Trade‑offs

- EKS control plane is publicly reachable (simplifies access); consider enabling private endpoint and restricting CIDRs for production.
- Worker nodes sit in public subnets; stateful dependencies are private. This is acceptable for demos; prefer private nodes with controlled egress for hardened environments.
- Single NAT gateway reduces cost but is a single AZ dependency; set `single_nat_gateway = false` for HA.
- IRSA provides least‑privilege pod access to AWS services (cards/DynamoDB). Extend this pattern to other services as needed.
- Add‑ons installed (ALB Controller, cert-manager) but no `Ingress` objects are defined here; external exposure requires adding them.

## Configuration Surface

- Key variables in `infra/terraform/variables.tf:1` include `cluster_name`, `cluster_version`, `region`, VPC CIDR/AZ count, node group sizes/types, encryption toggle, access principals, and backend management flags.
- Outputs expose VPC IDs, subnet IDs, cluster name and endpoint (`infra/terraform/outputs.tf:1`).

## Operating the Stack (essentials)

- Initialize and apply Terraform from `infra/terraform` with your chosen backend configuration. The README in that folder provides tested workflows and `aws eks update-kubeconfig` instructions (`infra/terraform/README.md:1`).
- After apply, use `kubectl` against the EKS cluster; workloads are already deployed by Terraform using the Kubernetes provider in `kubernetes_v2.tf`.
- For developer read‑only access, assume the created role and use `aws eks update-kubeconfig --role-arn ...` to gain view access.

## Extending

- External access: add `Ingress` resources with ALB annotations to expose `ui` (and optionally backend APIs) publicly.
- Observability: install metrics/logging (e.g., CloudWatch Container Insights, Prometheus/Grafana) via Helm or Blueprints Addons.
- Resilience: spread node groups across private subnets and enable EKS private endpoint; consider managed add‑ons (CoreDNS, KubeProxy) versions as needed.
- Security: add network policies, restrict SGs/CIDRs, and integrate secrets management (e.g., AWS Secrets Manager/External Secrets).

---

Scope note: This description is based solely on the Terraform under `infra/terraform`. Application‑level manifests or CI/CD outside this directory are intentionally out of scope.
