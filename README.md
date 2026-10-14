# Tech Challenge 3 — Infrastructure Guide

This guide walks you through provisioning the AWS infrastructure and deploying the five microservices from scratch. No prior Terraform experience required.

---

## What gets created

| Resource | Details |
|---|---|
| EKS Cluster | Kubernetes 1.32, t3.micro nodes (auto-scales 1–6) |
| RDS PostgreSQL | 3 independent db.t3.micro instances — auth-service, flag-service, targeting-service |
| ElastiCache Redis | 1 cache.t3.micro Redis node — used by evaluation-service |
| DynamoDB | 1 table (`analytics-events`) — used by analytics-service |
| SQS | 1 queue (`evaluation-events`) + Dead Letter Queue — shared by evaluation-service and analytics-service |
| ECR | 5 repositories — auth-service, flag-service, targeting-service, evaluation-service, analytics-service |

---

## Continuous delivery (GitOps)

This repository is also the **GitOps repository**. After a microservice pipeline
pushes an image to ECR, it commits the new tag into `charts/<service>/values.yaml`
here, and ArgoCD syncs the cluster automatically.

Setup (the `GITOPS_TOKEN` secret), design decisions and troubleshooting:
**[docs/CD-GITOPS.md](docs/CD-GITOPS.md)**.

---

## Alerting & Self-Healing

A Prometheus alert on the auth-service 5xx rate opens an incident in Jira
Service Management (OpsGenie's alerting engine, now part of JSM), posts a
detailed notification to Discord, and triggers a GitHub Action that runs
`kubectl rollout restart` automatically.

Setup, architecture and testing checklist: **[docs/ALERTING.md](docs/ALERTING.md)**.

---

## Part 1 — Install the tools

Install these on your machine before starting.

### Terraform

```bash
wget -O terraform.zip https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip
unzip terraform.zip
sudo mv terraform /usr/local/bin/
terraform -version
```

### AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

### kubectl

```bash
snap install kubectl --classic
kubectl version --client
```

### Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Docker

Follow the official guide for your OS: https://docs.docker.com/get-docker/

---

## Part 2 — Configure AWS credentials

Go to **AWS Console → IAM → Users → your user → Security credentials → Create access key**.

Then run:

```bash
aws configure
```

Enter your Access Key ID, Secret Access Key, region (`us-east-1`), and output format (`json`).

Verify it works:

```bash
aws sts get-caller-identity
# Should print your account ID and user ARN
```

> **Account requirement:** Creating 3 RDS instances requires a standard AWS account. The free-plan limits you to 1 RDS instance. Add a payment method in the AWS Console to remove that restriction before proceeding.

---

## Part 3 — Deploy ECR repositories

The ECR repositories must exist before you can push Docker images. This is a separate, lightweight Terraform deployment that only creates the 5 repositories.

```bash
cd terraform/ecr
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

When it completes, note the repository URLs:

```bash
terraform output repository_urls
```

You will need these URLs in Part 5 (pushing images) and Part 6 (Kubernetes manifests).

---

## Part 4 — Provision the full infrastructure

This step creates the EKS cluster, RDS databases, Redis, DynamoDB, SQS, and all IAM roles. Run all commands from the `terraform/` folder.

```bash
cd ../        # if you were in terraform/ecr
cd terraform  # or from the project root
```

### Step 1 — Initialize

```bash
terraform init
```

### Step 2 — Preview

```bash
terraform plan -out=tfplan
```

Review the output — you should see roughly 60 resources being created. Nothing is created yet.

### Step 3 — Apply

```bash
terraform apply tfplan
```

This takes **20–30 minutes**. The EKS cluster and RDS instances take the longest. Leave the terminal open until it finishes.

### Step 4 — Connect kubectl to the cluster

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name $(terraform output -raw eks_cluster_name)

kubectl get nodes
# Should show 2 nodes with status Ready
```

### Step 5 — Install Helm charts

Metrics Server, Nginx Ingress Controller, and KEDA are installed via a script after Terraform completes.

```bash
# Get the KEDA role ARN from Terraform output
KEDA_ROLE_ARN=$(terraform output -raw irsa_keda_role_arn)

# Go to the project root and run the script
cd ..
./scripts/helm-install.sh "$KEDA_ROLE_ARN"
```

The script installs all three charts and prints the load balancer hostname at the end. It takes about 3–5 minutes.

---

## Part 5 — Build and push Docker images

Run from the **project root**.

```bash
# Get your AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Log in to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    $AWS_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# Build each service image (adjust the source paths to match your project)
docker build -t auth-service:latest       ./auth-service
docker build -t flag-service:latest       ./flag-service
docker build -t targeting-service:latest  ./targeting-service
docker build -t evaluation-service:latest ./evaluation-service
docker build -t analytics-service:latest  ./analytics-service

# Push all images to ECR
./scripts/publish-images.sh us-east-1 $AWS_ACCOUNT_ID latest
```

---

## Part 6 — Collect connection strings

Run these from the `terraform/` folder. Copy and save all outputs — you will need them for the Kubernetes manifests.

```bash
# All connection info in one shot
terraform output -json connection_strings

# ECR image URLs
terraform output ecr_repository_urls

# RDS endpoints
terraform output -json rds_endpoints

# SQS queue URL
terraform output sqs_queue_url

# DynamoDB table name
terraform output dynamodb_table_name

# IRSA role ARNs for evaluation-service and analytics-service
terraform output irsa_evaluation_service_role_arn
terraform output irsa_analytics_service_role_arn
```

### Retrieve database passwords

Passwords are stored in AWS Secrets Manager, not in Terraform state.

```bash
# auth-service database credentials
aws secretsmanager get-secret-value \
  --secret-id tech-challenge-prod/rds/auth \
  --query SecretString --output text | jq .

# flag-service database credentials
aws secretsmanager get-secret-value \
  --secret-id tech-challenge-prod/rds/flag \
  --query SecretString --output text | jq .

# targeting-service database credentials
aws secretsmanager get-secret-value \
  --secret-id tech-challenge-prod/rds/targeting \
  --query SecretString --output text | jq .

# Redis auth token and endpoint (evaluation-service)
aws secretsmanager get-secret-value \
  --secret-id tech-challenge-prod/elasticache/redis \
  --query SecretString --output text | jq .
```

Each command returns a JSON with `host`, `port`, `username`, `password`, and `dbname`.

---

## Part 7 — Deploy to Kubernetes

### Step 1 — Fill in placeholder values in the manifests

The files under `k8s/` contain placeholders. Replace each one with the real value from the steps above.

| Placeholder | Command to get the value |
|---|---|
| `<ECR_URL>` | `cd terraform && terraform output -json ecr_repository_urls \| jq -r '.["auth-service"]'` (change service name as needed) |
| `<IRSA_ROLE_ARN>` in `evaluation-service/deployment.yaml` | `terraform output -raw irsa_evaluation_service_role_arn` |
| `<IRSA_ROLE_ARN>` in `analytics-service/deployment.yaml` | `terraform output -raw irsa_analytics_service_role_arn` |
| `<BASE64_DB_HOST>` | `echo -n "<host from Secrets Manager>" \| base64` |
| `<BASE64_DB_PASSWORD>` | `echo -n "<password from Secrets Manager>" \| base64` |
| `<BASE64_REDIS_HOST>` | `echo -n "<host from Secrets Manager>" \| base64` |
| `<BASE64_REDIS_AUTH_TOKEN>` | `echo -n "<auth_token from Secrets Manager>" \| base64` |
| `<BASE64_SQS_QUEUE_URL>` | `echo -n "$(terraform output -raw sqs_queue_url)" \| base64` |
| `<SQS_QUEUE_URL>` in `scaledobject.yaml` | `terraform output -raw sqs_queue_url` |

### Step 2 — Apply all manifests

```bash
# From the project root — applies everything in the correct order
./scripts/k8s-apply.sh
```

Or step by step:

```bash
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/auth-service/
kubectl apply -f k8s/flag-service/
kubectl apply -f k8s/targeting-service/
kubectl apply -f k8s/evaluation-service/
kubectl apply -f k8s/analytics-service/
kubectl apply -f k8s/ingress.yaml
```

### Step 3 — Get the public URL

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

The `EXTERNAL-IP` column shows the NLB hostname. It may take 2–3 minutes to appear after the Helm install.

| Path | Routes to |
|---|---|
| `<EXTERNAL-IP>/auth/` | auth-service |
| `<EXTERNAL-IP>/flags/` | flag-service |
| `<EXTERNAL-IP>/targeting/` | targeting-service |
| `<EXTERNAL-IP>/evaluate/` | evaluation-service |
| `<EXTERNAL-IP>/analytics/` | analytics-service |

---

## Tear down

### Destroy the full infrastructure

Before destroying, delete the Nginx Ingress load balancer from Kubernetes. If you don't, the NLB and its Elastic IPs will block the VPC from being deleted.

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx --ignore-not-found

# Wait ~30 seconds for AWS to remove the NLB, then:
cd terraform
terraform plan -destroy -out=tfplan-destroy
terraform apply tfplan-destroy
```

### Destroy only the ECR repositories

```bash
cd terraform/ecr
terraform plan -destroy -out=tfplan-destroy
terraform apply tfplan-destroy
```

> **Warning:** Destroying ECR will delete all repositories and every Docker image inside them. This cannot be undone.

> **Warning:** Destroying the full infrastructure permanently deletes all databases and their data. There are no automatic backups.
