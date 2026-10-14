output "self_healing_bot_access_key_id" {
  description = "Access key ID for the self-healing-bot IAM user — GitHub secret SELF_HEALING_AWS_ACCESS_KEY_ID"
  value       = aws_iam_access_key.self_healing_bot.id
}

output "self_healing_bot_secret_access_key" {
  description = "Secret access key for the self-healing-bot IAM user — GitHub secret SELF_HEALING_AWS_SECRET_ACCESS_KEY"
  value       = aws_iam_access_key.self_healing_bot.secret
  sensitive   = true
}

output "incident_relay_function_url" {
  description = "Lambda Function URL — set as the webhook_configs url for the 'incident-relay' Alertmanager receiver"
  value       = aws_lambda_function_url.incident_relay.function_url
}

output "relay_shared_secret" {
  description = "Bearer token Alertmanager must send to the relay — store as k8s Secret incident-relay-token (see docs/ALERTING.md)"
  value       = random_password.relay_shared_secret.result
  sensitive   = true
}
