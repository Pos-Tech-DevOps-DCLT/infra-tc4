# Alerting & Self-Healing — Jira Service Management (OpsGenie) + Discord + GitHub Actions (Membro 4)

Alerta inteligente no Prometheus, incidente automático no Jira Service
Management, notificação detalhada no Discord e self-healing (`kubectl
rollout restart`) disparado automaticamente — tudo a partir de uma única
métrica: a taxa de erro HTTP 5xx do `auth-service`.

> **Nota sobre o nome:** a Atlassian está descontinuando o OpsGenie
> standalone — contas novas e existentes estão migrando para dentro do
> **Jira Service Management (JSM) → Operations**, com desligamento do
> OpsGenie standalone previsto para abril/2027
> ([aviso oficial](https://support.atlassian.com/jira-service-management-cloud/docs/start-shifting-from-opsgenie-to-jira-service-management/)).
> A engine e a API de alertas são as mesmas de sempre (autenticação
> `GenieKey` + API Key) — só a marca e o lugar onde você cria a conta
> mudaram. Por isso o Alertmanager continua usando o campo nativo
> `opsgenie_configs` e o secret `opsgenie-api-key` abaixo: tecnicamente
> ainda é "o OpsGenie", só acessado através do JSM.

---

## O fluxo ponta a ponta

```
 Prometheus                  Alertmanager                 AWS Lambda              GitHub Actions        EKS
┌──────────────┐  dispara   ┌──────────────────┐ webhook  ┌───────────────┐ REST  ┌────────────────┐  kubectl ┌──────────┐
│ PrometheusRule│──────────▶│ route:            │─────────▶│ incident-relay│──────▶│ repository_    │─────────▶│auth-svc  │
│ AuthService   │  5xx > 5% │  service=auth-svc │  (bearer │  (reformata +  │ dispatch│ dispatch →    │  rollout │Deployment│
│ HighErrorRate │  por 5min │                   │   token) │   autentica)   │ event │ self-healing-  │  restart │          │
└──────────────┘            │  ├─ opsgenie ────▶│ JSM cria incidente         └───┬───┘ auth-service   └────────────────────┘
                             │  └─ incident-relay│                                │    .yml
                             └──────────────────┘                                 └──▶ Discord (ChatOps):
                                                                                        mensagem detalhada do incidente
```

**Por que existe o Lambda:** nem o `webhook_configs` do Alertmanager nem a
integração *Webhook* do Jira Service Management (JSM) permitem customizar o
corpo (body) JSON que enviam — os dois têm esquema fixo. A API `repository_dispatch` do GitHub
exige exatamente `{"event_type": ..., "client_payload": ...}`. O Lambda é só
o "tradutor" entre os dois formatos — ele **não** toca no cluster; o
`kubectl rollout restart` roda inteiramente dentro da GitHub Action.

Dois incidentes, uma causa raiz: o `auth-service` responde `401` para
qualquer erro de `/validate` (inclusive banco fora do ar) — ver nota em
[OTEL.md](OTEL.md#métricas-geradas-nomes-no-prometheus). O 5xx **real** do
auth-service normalmente vem do próprio processo/contêiner (OOM, crash loop,
banco inacessível na conexão TCP), não do handler — exatamente o cenário em
que reiniciar o pod ajuda.

---

## Boas práticas de Alert Fatigue aplicadas

| Técnica | Onde | Por quê |
|:--|:--|:--|
| `for: 5m` | `PrometheusRule` | Ignora picos de 1-2 requisições que se auto-resolvem; só dispara se o erro **persistir**. |
| Piso de tráfego (`> 0.05 req/s`) | `PrometheusRule` | Sem isso, 1 erro em 1 requisição = "100% de erro" num serviço quase sem tráfego — ruído estatístico, não incidente. |
| Roteamento por label (`service=auth-service`) | `alertmanager.config` | Só esse alerta vira incidente/notificação. As regras default do kube-prometheus-stack (Watchdog, etcd, scheduler — a maioria já desligada em `applications-observability.yaml`) caem no receiver `null`. |
| `group_by: [alertname, service]` + `group_interval: 5m` | `alertmanager.config` | Agrupa várias séries do mesmo alerta numa única notificação em vez de uma por série/pod. |
| `repeat_interval: 4h` | `alertmanager.config` | Não reabre o mesmo incidente a cada poucos minutos enquanto o problema persiste — só reforça a cada 4h. |
| `send_resolved: true` nos dois receivers | `alertmanager.config` | Fecha o loop: quando o erro volta a ficar abaixo de 5%, JSM e Discord recebem o "resolvido" — ninguém precisa fechar manualmente. |
| Self-healing só no "firing" | `incident_relay.py` | A notificação de "resolved" não deve disparar um novo restart. |

---

## Pré-requisitos (o que só você consegue fazer)

Eu não tenho como criar sua conta no Jira Service Management, seu webhook do
Discord ou o seu PAT do GitHub — são passos manuais, feitos uma única vez.

### 1. Conta no Jira Service Management (JSM) — plano Free

1. Criar conta gratuita em
   <https://www.atlassian.com/software/jira/service-management> (ou usar uma
   organização Atlassian/Jira já existente) e abrir a área **Operations**
   (é para onde o OpsGenie migrou — ver nota acima).
2. **Teams** → criar (ou usar) um time, ex. `tech-challenge`.
3. Dentro do time → **Integrations** → **Add integration** → buscar
   **"API"** (integração genérica por API Key — disponível no plano Free) e
   adicionar. Se o seu plano for Premium/Enterprise, a integração dedicada
   **"Prometheus"** também funciona e já vem com instruções prontas na tela;
   para quem está no Free, a **"API"** genérica é o caminho — o Alertmanager
   já fala o protocolo compatível (`opsgenie_configs`, header
   `Authorization: GenieKey <key>`), então qualquer uma das duas serve.
4. Copie a **API Key** gerada (campo "API Key" da integração).

> Os nomes exatos dos menus podem variar um pouco conforme a versão/plano do
> JSM — procure por **Operations**, **Alerts** ou **Teams** no menu
> principal se a navegação acima não bater exatamente.

### 2. Secret `opsgenie-api-key` no cluster

```bash
kubectl -n monitoring create secret generic opsgenie-api-key \
  --from-literal=api-key='<API Key do passo 1>'
```

### 3. Webhook do Discord

1. No canal do Discord → **Editar canal** → **Integrações** → **Webhooks** →
   **Novo Webhook** → nomear (ex. `alertas-auth-service`) → **Copiar URL do
   Webhook**.

### 4. PAT do GitHub para o `repository_dispatch`

Pode reaproveitar o mesmo PAT já criado para o `GITOPS_TOKEN` (mesmo
repositório, mesma permissão) — ver [CD-GITOPS.md](CD-GITOPS.md#pré-requisito-o-secret-gitops_token).
Se preferir um token dedicado:

1. GitHub → **Settings** → **Developer settings** → **Personal access
   tokens** → **Fine-grained tokens** → *Generate new token*.
2. **Resource owner**: `Pos-Tech-DevOps-DCLT` · **Repository access**: só
   `infra-tc4` · **Permissions** → **Contents: Read and write**.

### 5. Terraform — aplicar o módulo `alerting`

Adicione ao seu `terraform.tfvars` (nunca commitado — ver
`terraform.tfvars.example`):

```hcl
discord_webhook_url       = "<URL do passo 3>"
self_healing_github_token = "<PAT do passo 4>"
# self_healing_github_repo já tem default = "Pos-Tech-DevOps-DCLT/infra-tc4"
```

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Isso cria (ver `terraform/modules/alerting/`):

- IAM user `tech-challenge-prod-self-healing-bot` + access key (só
  `eks:DescribeCluster`, nada além);
- EKS access entry para esse user, com a policy gerenciada
  `AmazonEKSEditPolicy` **restrita ao namespace `auth-service`** — ele não
  enxerga nenhum outro namespace do cluster;
- o Lambda `tech-challenge-prod-incident-relay` (Function URL pública, mas
  protegida por bearer token — ver `incident_relay.py`).

### 6. Copiar as saídas do Terraform

```bash
# IAM do self-healing-bot -> secrets do GitHub (passo 7)
terraform output -raw self_healing_bot_access_key_id
terraform output -raw self_healing_bot_secret_access_key

# URL do Lambda -> substituir em argocd/applications-observability.yaml
terraform output -raw incident_relay_function_url

# Token do relay -> secret do cluster (passo 8)
terraform output -raw incident_relay_shared_secret
```

### 7. Secrets no GitHub (repositório `infra-tc4`)

**Settings** → **Secrets and variables** → **Actions** → *New repository
secret*:

| Nome | Valor |
|:--|:--|
| `SELF_HEALING_AWS_ACCESS_KEY_ID` | saída `self_healing_bot_access_key_id` |
| `SELF_HEALING_AWS_SECRET_ACCESS_KEY` | saída `self_healing_bot_secret_access_key` |

### 8. Secret `incident-relay-token` no cluster

```bash
kubectl -n monitoring create secret generic incident-relay-token \
  --from-literal=token="$(terraform output -raw incident_relay_shared_secret)"
```

### 9. Preencher a URL do Lambda e aplicar

Em `argocd/applications-observability.yaml`, troque
`<INCIDENT_RELAY_FUNCTION_URL>` (receiver `incident-relay`) pelo valor do
passo 6, depois:

```bash
kubectl apply -f argocd/applications-observability.yaml
kubectl -n argocd get application kube-prometheus-stack   # Synced / Healthy
```

### 10. Aplicar o alerta e o self-healing

```bash
kubectl apply -f argocd/applications-observability.yaml   # já inclui o PrometheusRule
kubectl -n monitoring get prometheusrule auth-service-alerts
```

O workflow `.github/workflows/self-healing-auth-service.yml` já está
versionado no repo — nenhum passo manual adicional além dos secrets acima.

---

## Como testar o fluxo completo

### 1. Teste isolado do self-healing (sem esperar o alerta)

```bash
gh workflow run self-healing-auth-service.yml -f reason="teste manual"
gh run watch
```

Confirma sozinho: credenciais AWS do bot + EKS access entry + `kubectl
rollout restart` funcionando — antes de depender do alerta de verdade.

### 2. Teste do relay (sem esperar o Prometheus)

```bash
curl -i -X POST "$(terraform output -raw incident_relay_function_url)" \
  -H "Authorization: Bearer $(terraform output -raw incident_relay_shared_secret)" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "firing",
    "commonLabels": {"service": "auth-service", "severity": "critical"},
    "commonAnnotations": {
      "summary": "auth-service: taxa de erro HTTP 5xx acima de 5% (teste)",
      "description": "Disparo manual para validar o relay."
    },
    "alerts": [{"status": "firing"}]
  }'
```

Confirma: mensagem chega no Discord **e** o workflow do GitHub Actions é
disparado (`gh run list --workflow=self-healing-auth-service.yml`).

### 3. Teste ponta a ponta (gera o incidente de verdade)

Provoque 5xx real no `auth-service` — por exemplo, derrubando
temporariamente o RDS dele ou escalando o deployment para 0 réplicas por
alguns segundos e gerando tráfego:

```bash
INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

kubectl -n auth-service scale deployment/auth-service --replicas=0
hey -z 6m -c 5 "http://$INGRESS_HOST/evaluate/evaluate?user_id=u1&flag_name=demo"
# restaure manualmente se o self-healing não disparar a tempo:
kubectl -n auth-service scale deployment/auth-service --replicas=1
```


# 1. Cut auth-service's DB connectivity only (pod stays Running — /health doesn't touch the DB)
kubectl apply -f /tmp/claude-1000/-home-gabri-Tech-Challenge-4-infra-tc4/a5c399f2-5004-4c9a-95c7-35997aec9869/scratchpad/block-auth-rds.yaml
kubectl -n auth-service get pods   # should still show Running/Ready

# 2. Get the MASTER_KEY (run this yourself — I shouldn't see the value)
MASTER_KEY=$(kubectl -n auth-service get secret auth-service-secret -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

# 3. Hit the ONE endpoint that returns a real 500 on DB failure: POST /admin/keys
INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 6m -c 5 -m POST \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"load-test-key"}' \
  "http://$INGRESS_HOST/auth/admin/keys"

# 4. Watch Prometheus Alerts tab for AuthServiceHighErrorRate going Pending -> Firing (~5 min in)
#    Then check OpsGenie, Discord, and `gh run list --workflow=self-healing-auth-service.yml`

# 5. Cleanup — restore DB access once you've seen the full loop complete
kubectl delete -f /tmp/claude-1000/-home-gabri-Tech-Challenge-4-infra-tc4/a5c399f2-5004-4c9a-95c7-35997aec9869/scratchpad/block-auth-rds.yaml




Checklist:

- [ ] Prometheus → **Alerts**: `AuthServiceHighErrorRate` passa de `Pending`
      para `Firing` após ~5 minutos.
- [ ] JSM: incidente aberto (prioridade P2), com o `summary`/`description`
      da regra.
- [ ] Discord: mensagem detalhada no canal (serviço, severidade, nº de
      alertas, aviso de self-healing).
- [ ] GitHub Actions: run de `self-healing-auth-service.yml` concluído com
      sucesso (`gh run list`).
- [ ] `kubectl -n auth-service get pods` mostra pods novos (restart
      executado).
- [ ] Alerta volta a `Inactive` e JSM/Discord recebem o "resolvido".

---

## Runbook — se o self-healing não resolver

O restart cobre a causa mais comum (processo travado, conexão de banco
pendurada, memory leak lento). Se o alerta continuar firing depois do
restart:

1. **Logs** (Loki): `{service_name="auth-service"} |= "Erro"` — ver
   [OTEL.md](OTEL.md#logs-no-loki).
2. **Traces/erros** (New Relic APM): `auth-service` → Errors inbox — ver
   [APM.md](APM.md).
3. **Banco**: `auth-service` fala com RDS `authdb` — confirmar que a
   instância está `available` (`aws rds describe-db-instances`).
4. **Deploy recente**: se o 5xx começou logo após um deploy, considere
   reverter a tag em `charts/auth-service/values.yaml` para o `image.tag`
   anterior (commit + ArgoCD sincroniza sozinho) em vez de esperar outro
   restart.
5. Se nada resolver, escalar manualmente no JSM (**Alert** → **Escalate**).

---

## Problemas comuns

| Sintoma | Causa provável |
|:--|:--|
| Alerta nunca fica `Firing` no Prometheus | Sem tráfego suficiente (piso de 0.05 req/s) — gere tráfego real, não só `/health` (ver nota em [OTEL.md](OTEL.md)) |
| `Firing` mas nada chega no JSM | Secret `opsgenie-api-key` ausente/errado, ou API Key de integração do tipo errado |
| JSM ok, Discord/self-healing não disparam | Secret `incident-relay-token` ausente, ou `<INCIDENT_RELAY_FUNCTION_URL>` não foi substituída em `applications-observability.yaml` |
| Lambda responde `401` | Token em `incident-relay-token` não bate com `terraform output incident_relay_shared_secret` (reaplicar o secret) |
| Lambda responde 200 mas Discord não recebe nada | `discord_webhook_url` errado/expirado no `terraform.tfvars` — `terraform apply` de novo após corrigir |
| `repository_dispatch` falha (403/404) | PAT sem **Contents: Read and write** em `infra-tc4`, ou expirado |
| GitHub Action falha no `aws eks update-kubeconfig` | Secrets `SELF_HEALING_AWS_*` ausentes, ou IAM user sem `eks:DescribeCluster` |
| GitHub Action falha no `kubectl rollout restart` (Forbidden) | EKS access entry não associada, ou namespace errado no `access_scope` |

---

## Arquivos envolvidos

| Arquivo | Papel |
|:--|:--|
| `charts/observability-extras/templates/auth-service-alerts.yaml` | `PrometheusRule` — regra de 5xx do auth-service |
| `argocd/applications-observability.yaml` | `alertmanager.config` — roteamento para JSM + relay |
| `terraform/modules/alerting/` | IAM scoped do self-healing-bot, EKS access entry, Lambda relay |
| `.github/workflows/self-healing-auth-service.yml` | Self-healing — `kubectl rollout restart` |
| `scripts/self-heal-auth-service.sh` | Lógica do restart + espera do rollout |
| `terraform/modules/alerting/lambda/incident_relay.py` | Relay: Alertmanager → Discord + GitHub `repository_dispatch` |
