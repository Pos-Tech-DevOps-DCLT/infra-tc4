# ── EKS ───────────────────────────────────────────────────────────────────────
output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "eks_cluster_endpoint" {
  description = "Endpoint of the EKS cluster"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "eks_node_group_arn" {
  description = "ARN of the EKS managed node group"
  value       = module.eks.node_group_arn
}

# ── ECR ───────────────────────────────────────────────────────────────────────
output "ecr_repository_urls" {
  description = "ECR repository URLs — one per microservice"
  value       = module.ecr.repository_urls
}

# ── RDS ───────────────────────────────────────────────────────────────────────
output "rds_endpoints" {
  description = "RDS endpoints — host:port for each service (auth / flag / targeting)"
  value       = module.rds.endpoints
  sensitive   = true
}

output "rds_port" {
  description = "PostgreSQL port (same for all RDS instances)"
  value       = 5432
}

output "rds_secret_arns" {
  description = "Secrets Manager ARNs containing credentials for each RDS instance"
  value       = module.rds.secret_arns
}

# ── ElastiCache Redis ──────────────────────────────────────────────────────────
output "elasticache_endpoint" {
  description = "ElastiCache Redis primary endpoint (used by evaluation-service)"
  value       = module.elasticache.primary_endpoint
  sensitive   = true
}

output "elasticache_port" {
  description = "ElastiCache Redis port"
  value       = module.elasticache.port
}

output "elasticache_secret_arn" {
  description = "Secrets Manager ARN containing the Redis auth token and endpoint"
  value       = module.elasticache.secret_arn
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────
output "dynamodb_table_name" {
  description = "DynamoDB table name (used by analytics-service)"
  value       = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = module.dynamodb.table_arn
}

# ── SQS ───────────────────────────────────────────────────────────────────────
output "sqs_queue_url" {
  description = "SQS queue URL (used by evaluation-service to produce and analytics-service to consume)"
  value       = module.sqs.queue_url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN"
  value       = module.sqs.queue_arn
}

output "sqs_queue_name" {
  description = "SQS queue name"
  value       = module.sqs.queue_name
}

output "sqs_dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = module.sqs.dlq_url
}

# ── IRSA Roles ────────────────────────────────────────────────────────────────
output "irsa_keda_role_arn" {
  description = "IRSA role ARN for KEDA operator (annotate the keda ServiceAccount with this)"
  value       = module.irsa.keda_role_arn
}

output "irsa_evaluation_service_role_arn" {
  description = "IRSA role ARN for evaluation-service (SQS producer)"
  value       = module.irsa.evaluation_service_role_arn
}

output "irsa_analytics_service_role_arn" {
  description = "IRSA role ARN for analytics-service (SQS consumer + DynamoDB writer)"
  value       = module.irsa.analytics_service_role_arn
}

# ── VPC ───────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

# ── Connection Strings Summary ────────────────────────────────────────────────
# All values needed for the next step (Kubernetes manifests / app config).
# Sensitive values (endpoints, passwords) must be retrieved via Secrets Manager
# or with: terraform output -json connection_strings
output "connection_strings" {
  description = "All connection strings needed for the next deployment step"
  sensitive   = true
  value = {
    "# EKS" = {
      cluster_name = module.eks.cluster_name
    }

    "# ECR repositories" = {
      for name, url in module.ecr.repository_urls : name => url
    }

    "# RDS — auth-service" = {
      endpoint   = try(module.rds.endpoints["auth"], "")
      port       = 5432
      secret_arn = try(module.rds.secret_arns["auth"], "")
    }

    "# RDS — flag-service" = {
      endpoint   = try(module.rds.endpoints["flag"], "")
      port       = 5432
      secret_arn = try(module.rds.secret_arns["flag"], "")
    }

    "# RDS — targeting-service" = {
      endpoint   = try(module.rds.endpoints["targeting"], "")
      port       = 5432
      secret_arn = try(module.rds.secret_arns["targeting"], "")
    }

    "# ElastiCache Redis — evaluation-service" = {
      endpoint   = module.elasticache.primary_endpoint
      port       = module.elasticache.port
      secret_arn = module.elasticache.secret_arn
    }

    "# DynamoDB — analytics-service" = {
      table_name = module.dynamodb.table_name
      table_arn  = module.dynamodb.table_arn
    }

    "# SQS — evaluation-service (producer) + analytics-service (consumer)" = {
      queue_url  = module.sqs.queue_url
      queue_arn  = module.sqs.queue_arn
      queue_name = module.sqs.queue_name
      dlq_url    = module.sqs.dlq_url
    }

    "# IRSA — annotate each ServiceAccount with its role ARN" = {
      keda               = module.irsa.keda_role_arn
      evaluation_service = module.irsa.evaluation_service_role_arn
      analytics_service  = module.irsa.analytics_service_role_arn
    }
  }
}

# ── Alerting & Self-Healing (Membro 4) ────────────────────────────────────────
# See docs/ALERTING.md for what to do with each of these.
output "self_healing_bot_access_key_id" {
  description = "Access key ID for the self-healing-bot IAM user — GitHub secret SELF_HEALING_AWS_ACCESS_KEY_ID"
  value       = module.alerting.self_healing_bot_access_key_id
}

output "self_healing_bot_secret_access_key" {
  description = "Secret access key for the self-healing-bot IAM user — GitHub secret SELF_HEALING_AWS_SECRET_ACCESS_KEY"
  value       = module.alerting.self_healing_bot_secret_access_key
  sensitive   = true
}

output "incident_relay_function_url" {
  description = "Lambda Function URL — set as the webhook_configs url for the Alertmanager 'incident-relay' receiver in argocd/applications-observability.yaml"
  value       = module.alerting.incident_relay_function_url
}

output "incident_relay_shared_secret" {
  description = "Bearer token Alertmanager must send to the relay — store as k8s Secret incident-relay-token"
  value       = module.alerting.relay_shared_secret
  sensitive   = true
}
