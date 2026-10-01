# General
aws_region   = "us-east-1"
project_name = "tech-challenge"
environment  = "prod"

# VPC
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# EKS
eks_cluster_version     = "1.36"
eks_node_instance_types = ["m7i-flex.large"]
eks_node_desired_size   = 4
eks_node_min_size       = 2
eks_node_max_size       = 10
eks_node_disk_size      = 20

# ECR (5 repositories — one per microservice)
ecr_repositories = [
  "auth-service",
  "flag-service",
  "targeting-service",
  "evaluation-service",
  "analytics-service"
]
ecr_image_retention_count = 10

# RDS — 3 independent PostgreSQL instances (one per service), as required
rds_engine_version = "15.8"
rds_username       = "dbadmin"
rds_multi_az       = false

rds_instances = {
  auth = {
    db_name           = "authdb"
    instance_class    = "db.t3.micro"
    allocated_storage = 20
  }
  flag = {
    db_name           = "flagdb"
    instance_class    = "db.t3.micro"
    allocated_storage = 20
  }
  targeting = {
    db_name           = "targetingdb"
    instance_class    = "db.t3.micro"
    allocated_storage = 20
  }
}

# ElastiCache Redis
elasticache_node_type       = "cache.t3.micro"
elasticache_num_cache_nodes = 1
elasticache_engine_version  = "7.0"

# DynamoDB — analytics-service event store
dynamodb_table_name   = "analytics-events"
dynamodb_billing_mode = "PAY_PER_REQUEST"
dynamodb_hash_key     = "event_id"
dynamodb_range_key    = ""

# SQS — evaluation-service (producer) → analytics-service (consumer)
sqs_queue_name                = "evaluation-events"
sqs_visibility_timeout        = 30
sqs_message_retention_seconds = 86400
sqs_enable_dlq                = true
sqs_max_receive_count         = 3
