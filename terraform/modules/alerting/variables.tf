variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster (for the access entry and update-kubeconfig)"
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the EKS cluster (scopes the self-healing-bot IAM policy)"
  type        = string
}

variable "discord_webhook_url" {
  description = "Discord channel webhook URL used for incident ChatOps notifications"
  type        = string
  sensitive   = true
}

variable "github_repo" {
  description = "owner/repo of this GitOps repository (used for repository_dispatch)"
  type        = string
}

variable "github_token" {
  description = "Fine-grained GitHub PAT with 'Contents: Read and write' on github_repo — triggers repository_dispatch. Can reuse the same PAT created for GITOPS_TOKEN."
  type        = string
  sensitive   = true
}
