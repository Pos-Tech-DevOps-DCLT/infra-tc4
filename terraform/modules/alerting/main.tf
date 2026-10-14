# ---------------------------------------------------------------------------
# Alerting & Self-Healing (Membro 4)
#
#   Prometheus (AuthServiceHighErrorRate) -> Alertmanager
#     ├─ receiver "opsgenie"       -> Jira Service Management / Operations
#                                      (OpsGenie's alerting engine, now part
#                                      of JSM — incident management)
#     └─ receiver "incident-relay" -> Lambda Function URL (this module)
#                                       ├─ Discord webhook (ChatOps)
#                                       └─ GitHub repository_dispatch
#                                            -> self-healing-auth-service.yml
#                                               -> kubectl rollout restart
#                                                  (via the IAM user + EKS
#                                                  access entry below, scoped
#                                                  to the auth-service namespace)
#
# See docs/ALERTING.md for the full setup (Jira Service Management account,
# Discord webhook, GitHub/k8s secrets) — most of it is manual, outside
# Terraform's reach.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# self-healing-bot — scoped IAM user used by the GitHub Action to reach EKS.
# IAM only grants eks:DescribeCluster (needed for `aws eks update-kubeconfig`);
# actual in-cluster permissions come from the EKS access entry below, which is
# restricted to the auth-service namespace with the built-in "edit" policy —
# enough to patch/restart a Deployment, nothing in any other namespace.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "self_healing_bot" {
  name = "${var.name_prefix}-self-healing-bot"
}

resource "aws_iam_access_key" "self_healing_bot" {
  user = aws_iam_user.self_healing_bot.name
}

resource "aws_iam_user_policy" "self_healing_bot_describe_cluster" {
  name = "${var.name_prefix}-self-healing-describe-cluster"
  user = aws_iam_user.self_healing_bot.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = var.cluster_arn
    }]
  })
}

resource "aws_eks_access_entry" "self_healing_bot" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_user.self_healing_bot.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "self_healing_bot_edit_auth_service" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_user.self_healing_bot.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["auth-service"]
  }

  depends_on = [aws_eks_access_entry.self_healing_bot]
}

# ---------------------------------------------------------------------------
# Shared secret used by Alertmanager to authenticate to the relay Lambda
# (bearer token, checked in incident_relay.py). Generated here instead of
# asked from the user so nothing sensitive has to be invented/typed by hand;
# it still needs to be copied once into a k8s Secret (see docs/ALERTING.md),
# same "secret created outside Git" pattern as newrelic-license / grafana-admin.
# ---------------------------------------------------------------------------
resource "random_password" "relay_shared_secret" {
  length  = 32
  special = false
}

# ---------------------------------------------------------------------------
# Incident relay — AWS Lambda (Function URL, no API Gateway needed)
# ---------------------------------------------------------------------------
data "archive_file" "incident_relay" {
  type        = "zip"
  source_file = "${path.module}/lambda/incident_relay.py"
  output_path = "${path.module}/lambda/incident_relay.zip"
}

resource "aws_iam_role" "incident_relay" {
  name = "${var.name_prefix}-incident-relay-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "incident_relay_logs" {
  role       = aws_iam_role.incident_relay.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "incident_relay" {
  function_name    = "${var.name_prefix}-incident-relay"
  role             = aws_iam_role.incident_relay.arn
  handler          = "incident_relay.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.incident_relay.output_path
  source_code_hash = data.archive_file.incident_relay.output_base64sha256

  environment {
    variables = {
      RELAY_SHARED_SECRET = random_password.relay_shared_secret.result
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
      GITHUB_REPO         = var.github_repo
      GITHUB_TOKEN        = var.github_token
    }
  }
}

# authorization_type = NONE: the function itself checks the bearer token
# (RELAY_SHARED_SECRET) before doing anything — see incident_relay.py.
# IAM auth isn't an option here because Alertmanager can't sign requests
# with SigV4.
resource "aws_lambda_function_url" "incident_relay" {
  function_name      = aws_lambda_function.incident_relay.function_name
  authorization_type = "NONE"
}

# authorization_type = NONE on the function URL only controls whether AWS
# *requires* SigV4 — it does NOT grant public invoke by itself. Without this
# resource-based permission, every request (signed or not) gets a 403
# AccessDeniedException straight from AWS, before incident_relay.py ever runs.
resource "aws_lambda_permission" "incident_relay_public_url" {
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.incident_relay.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}
