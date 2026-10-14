"""Incident relay — bridges Alertmanager's webhook to Discord + GitHub Actions.

Why this exists: neither Alertmanager's webhook_configs nor the Jira Service
Management (OpsGenie) Webhook integration let you template the JSON body they send, but GitHub's
repository_dispatch API requires an exact {event_type, client_payload} shape.
This function is the glue — it does NOT touch the Kubernetes cluster. The
actual self-healing (kubectl rollout restart) runs entirely inside the
GitHub Action it triggers.

Env vars: RELAY_SHARED_SECRET, DISCORD_WEBHOOK_URL, GITHUB_REPO, GITHUB_TOKEN.
"""

import base64
import json
import os
import urllib.error
import urllib.request

FIRING_COLOR = 15158332  # red
RESOLVED_COLOR = 3066993  # green


def _post(url, payload, headers):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8")
    except urllib.error.URLError as exc:
        return None, str(exc.reason)


def _discord_message(alert_payload):
    status = alert_payload.get("status", "firing")
    labels = alert_payload.get("commonLabels", {})
    annotations = alert_payload.get("commonAnnotations", {})
    service = labels.get("service", "unknown")
    severity = labels.get("severity", "unknown")
    alert_count = len(alert_payload.get("alerts", [])) or 1

    if status == "firing":
        emoji, color = "🔥", FIRING_COLOR
    else:
        emoji, color = "✅", RESOLVED_COLOR

    fields = [
        {"name": "Serviço", "value": service, "inline": True},
        {"name": "Severidade", "value": severity, "inline": True},
        {"name": "Alertas ativos", "value": str(alert_count), "inline": True},
    ]
    if status == "firing":
        fields.append(
            {
                "name": "Self-healing",
                "value": "`kubectl rollout restart deployment/auth-service` acionado via GitHub Actions.",
                "inline": False,
            }
        )

    return {
        "embeds": [
            {
                "title": f"{emoji} [{status.upper()}] {annotations.get('summary', 'Incidente em ' + service)}",
                "description": annotations.get("description", ""),
                "color": color,
                "fields": fields,
            }
        ]
    }


def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    expected = f"Bearer {os.environ['RELAY_SHARED_SECRET']}"
    if headers.get("authorization") != expected:
        return {"statusCode": 401, "body": "unauthorized"}

    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    alert_payload = json.loads(body)
    status = alert_payload.get("status", "firing")

    discord_url = os.environ.get("DISCORD_WEBHOOK_URL")
    discord_status = None
    if discord_url:
        discord_status, _ = _post(
            discord_url,
            _discord_message(alert_payload),
            {"Content-Type": "application/json"},
        )

    dispatch_status = None
    if status == "firing":
        dispatch_status, _ = _post(
            f"https://api.github.com/repos/{os.environ['GITHUB_REPO']}/dispatches",
            {
                "event_type": "auth-service-incident",
                "client_payload": {
                    "alerts": alert_payload.get("alerts", []),
                    "commonLabels": alert_payload.get("commonLabels", {}),
                    "commonAnnotations": alert_payload.get("commonAnnotations", {}),
                },
            },
            {
                "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )

    return {
        "statusCode": 200,
        "body": json.dumps({"discord_status": discord_status, "dispatch_status": dispatch_status}),
    }
