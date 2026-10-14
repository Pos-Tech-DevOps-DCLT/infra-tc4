locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "security_groups" {
  source = "./modules/security_groups"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.vpc_cidr
}

module "eks" {
  source = "./modules/eks"

  name_prefix         = local.name_prefix
  cluster_version     = var.eks_cluster_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = var.eks_node_instance_types
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size
  node_disk_size      = var.eks_node_disk_size
  cluster_sg_id       = module.security_groups.eks_cluster_sg_id
  node_sg_id          = module.security_groups.eks_node_sg_id
}

module "ecr" {
  source = "./modules/ecr"

  name_prefix           = local.name_prefix
  repository_names      = var.ecr_repositories
  image_retention_count = var.ecr_image_retention_count
}

module "rds" {
  source = "./modules/rds"

  name_prefix        = local.name_prefix
  rds_instances      = var.rds_instances
  engine_version     = var.rds_engine_version
  master_username    = var.rds_username
  multi_az           = var.rds_multi_az
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.rds_sg_id]
}

module "elasticache" {
  source = "./modules/elasticache"

  name_prefix        = local.name_prefix
  node_type          = var.elasticache_node_type
  num_cache_nodes    = var.elasticache_num_cache_nodes
  engine_version     = var.elasticache_engine_version
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.elasticache_sg_id]
}

module "dynamodb" {
  source = "./modules/dynamodb"

  name_prefix  = local.name_prefix
  table_name   = var.dynamodb_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = var.dynamodb_hash_key
  range_key    = var.dynamodb_range_key
}

module "sqs" {
  source = "./modules/sqs"

  name_prefix               = local.name_prefix
  queue_name                = var.sqs_queue_name
  visibility_timeout        = var.sqs_visibility_timeout
  message_retention_seconds = var.sqs_message_retention_seconds
  enable_dlq                = var.sqs_enable_dlq
  max_receive_count         = var.sqs_max_receive_count
}

# ---------------------------------------------------------------------------
# IRSA — per-service IAM roles bound to Kubernetes ServiceAccounts
# ---------------------------------------------------------------------------
module "irsa" {
  source = "./modules/irsa"

  name_prefix       = local.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.cluster_oidc_issuer_url
  sqs_queue_arn     = module.sqs.queue_arn
  sqs_queue_url     = module.sqs.queue_url
  sqs_dlq_arn       = module.sqs.dlq_arn
  dynamodb_table_arn = module.dynamodb.table_arn

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Alerting & Self-Healing (Membro 4) — see terraform/modules/alerting/main.tf
# ---------------------------------------------------------------------------
module "alerting" {
  source = "./modules/alerting"

  name_prefix         = local.name_prefix
  cluster_name        = module.eks.cluster_name
  cluster_arn         = module.eks.cluster_arn
  discord_webhook_url = var.discord_webhook_url
  github_repo         = var.self_healing_github_repo
  github_token        = var.self_healing_github_token

  depends_on = [module.eks]
}

# Helm charts (metrics-server, nginx-ingress, KEDA) are installed by
# scripts/helm-install.sh after terraform apply completes.
