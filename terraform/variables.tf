variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used as prefix for all resources"
  type        = string
  default     = "tech-challenge"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

# VPC
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# EKS
variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 4
}

variable "eks_node_disk_size" {
  description = "Disk size in GiB for EKS worker nodes"
  type        = number
  default     = 20
}

# ECR
variable "ecr_repositories" {
  description = "List of ECR repository names to create (one per microservice)"
  type        = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service"
  ]
}

variable "ecr_image_retention_count" {
  description = "Number of images to retain in each ECR repository"
  type        = number
  default     = 10
}

# RDS
variable "rds_instances" {
  description = "Map of RDS PostgreSQL instances to create (one per service)"
  type = map(object({
    db_name           = string
    instance_class    = string
    allocated_storage = number
  }))
  default = {
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
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15.8"
}

variable "rds_username" {
  description = "Master username for all RDS instances"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS instances"
  type        = bool
  default     = false
}

# ElastiCache
variable "elasticache_node_type" {
  description = "Instance type for ElastiCache Redis nodes"
  type        = string
  default     = "cache.t3.micro"
}

variable "elasticache_num_cache_nodes" {
  description = "Number of cache nodes in the ElastiCache cluster"
  type        = number
  default     = 1
}

variable "elasticache_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

# DynamoDB — used by analytics-service
variable "dynamodb_table_name" {
  description = "Name suffix for the DynamoDB table (used by analytics-service)"
  type        = string
  default     = "analytics-events"
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode (PAY_PER_REQUEST or PROVISIONED)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "dynamodb_hash_key" {
  description = "Hash key attribute name for the DynamoDB table"
  type        = string
  default     = "event_id"
}

variable "dynamodb_range_key" {
  description = "Range key attribute name for the DynamoDB table (optional, leave empty to omit)"
  type        = string
  default     = ""
}

# SQS — shared between evaluation-service (producer) and analytics-service (consumer)
variable "sqs_queue_name" {
  description = "Name suffix for the SQS Standard queue"
  type        = string
  default     = "evaluation-events"
}

variable "sqs_visibility_timeout" {
  description = "Visibility timeout in seconds for SQS messages"
  type        = number
  default     = 30
}

variable "sqs_message_retention_seconds" {
  description = "Message retention period in seconds"
  type        = number
  default     = 86400
}

variable "sqs_enable_dlq" {
  description = "Enable a Dead Letter Queue for the SQS queue"
  type        = bool
  default     = true
}

variable "sqs_max_receive_count" {
  description = "Number of times a message can be received before being sent to the DLQ"
  type        = number
  default     = 3
}

# Alerting & Self-Healing (Membro 4) — see docs/ALERTING.md
variable "discord_webhook_url" {
  description = "Discord channel webhook URL for incident ChatOps notifications"
  type        = string
  sensitive   = true
}

variable "self_healing_github_repo" {
  description = "owner/repo that hosts the self-healing GitHub Action (this repo)"
  type        = string
  default     = "Pos-Tech-DevOps-DCLT/infra-tc4"
}

variable "self_healing_github_token" {
  description = "Fine-grained GitHub PAT ('Contents: Read and write' on self_healing_github_repo) used by the incident-relay Lambda to trigger repository_dispatch. Can reuse the same PAT created for GITOPS_TOKEN."
  type        = string
  sensitive   = true
}
