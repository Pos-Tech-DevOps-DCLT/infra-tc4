# APM — New Relic + Distributed Tracing + Service Map (Fase 4, Parte 3)

Os 5 serviços já mandam traces OTLP para o OTel Collector (ver [OTEL.md](OTEL.md)).
Esta parte só liga a saída do pipeline `traces` do Collector ao New Relic —
nenhuma aplicação muda.

```
5 microsserviços ──OTLP──▶ otel-collector ──┬─ traces ─▶ debug + otlphttp/newrelic ──▶ otlp.nr-data.net (APM)
                                            ├─ metrics ─▶ Prometheus
                                            └─ logs ────▶ Loki
```

Config: [`argocd/applications-observability.yaml`](../argocd/applications-observability.yaml)
(Application `otel-collector`: `extraEnvs` + exporter `otlphttp/newrelic` + pipeline `traces`).

## Por que New Relic (e não Datadog)

| Critério | New Relic | Datadog |
|---|---|---|
| Plano gratuito | Permanente: 100 GB/mês de ingestão, APM/tracing incluídos, sem cartão | Free tier não inclui APM; só trial de 14 dias (pode expirar antes da apresentação) |
| Integração com OTel Collector | OTLP nativo: exporter genérico `otlphttp` + header `api-key` | Exporter proprietário `datadog` + connector `datadog/connector` para gerar as métricas de APM do Service Map |
| Lock-in | Nenhum: trocar de APM = trocar o endpoint do exporter | Componentes específicos do fornecedor no pipeline |
| Service Map / trace distribuído | Gerados direto dos spans OTel (`service.name`, `span.kind`, `traceparent`) | Idem, mas dependem do connector |

Resumo para o relatório: o New Relic recebe OTLP nativamente, então mantém a
arquitetura 100% padronizada em OpenTelemetry (o Collector continua sendo a única
peça que conhece o backend) e o free tier cobre APM sem prazo de expiração.

## Passo a passo

> **Atalhos:** `scripts/apm-local-test.sh` testa a license key sem o cluster
> (Collector + `telemetrygen` no Docker); `scripts/apm-enable.sh` faz os
> passos 2 a 5 de uma vez com o cluster ligado.

### 1. Conta e license key

1. Criar conta em <https://newrelic.com/signup> (região **US**; se escolher EU,
   trocar o endpoint do exporter para `https://otlp.eu01.nr-data.net`).
2. `one.newrelic.com` → avatar → **API Keys** → copiar a chave do tipo
   **INGEST - LICENSE** (40 caracteres, termina em `NRAL`).

> **Atenção (free tier):** só 1 usuário *Full platform*; usuários *Basic* não
> abrem as telas de APM / Distributed tracing / Service map. A gravação do
> trecho de APM do vídeo precisa ser feita logado com o usuário Full (o dono da
> conta), ou o grupo compartilha esse login.

### 2. Secret no cluster (fora do Git)

```bash
kubectl -n monitoring create secret generic newrelic-license \
  --from-literal=license-key='<INGEST - LICENSE key>'
```

O `secretKeyRef` é `optional: true`: sem o Secret o Collector sobe normalmente
(métricas/logs não são afetados), só o export para o New Relic falha com 403.

### 3. Aplicar

O manifesto `applications-observability.yaml` é aplicado à mão (não há
app-of-apps observando esse arquivo); depois disso o ArgoCD sincroniza o chart:

```bash
kubectl apply -f argocd/applications-observability.yaml
kubectl -n argocd get application otel-collector        # Synced / Healthy

# O env vem de um Secret criado depois do pod: reiniciar para o Collector lê-lo
kubectl -n monitoring rollout restart ds/otel-collector-agent
kubectl -n monitoring rollout status  ds/otel-collector-agent
```

### 4. Gerar tráfego real

```bash
INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s "http://$INGRESS_HOST/evaluate/evaluate?user_id=u1&flag_name=demo"
hey -z 60s -c 5 "http://$INGRESS_HOST/evaluate/evaluate?user_id=u1&flag_name=demo"
```

`/health` é excluído da telemetria — o `scripts/load-test.sh` não gera traces.

### 5. Validar

**Collector** (sem erros de export):

```bash
kubectl -n monitoring logs ds/otel-collector-agent --since=5m | grep -iE "newrelic|403|error"
kubectl -n monitoring logs ds/otel-collector-agent --since=2m | grep -E "Traces|spans"
```

**New Relic → Query your data (NRQL)**:

```sql
-- os 5 serviços estão mandando spans?
FROM Span SELECT count(*) FACET service.name SINCE 30 minutes ago

-- traces que atravessam serviços (esperado: 4 ou 5 serviços no mesmo trace.id)
FROM Span SELECT uniqueCount(service.name) AS 'servicos', count(*) AS 'spans'
FACET trace.id SINCE 30 minutes ago LIMIT 10

-- tags que o APM usa para correlacionar
FROM Span SELECT latest(span.kind), latest(k8s.namespace.name),
  latest(deployment.environment), latest(service.version)
FACET service.name SINCE 30 minutes ago
```

**Checklist**

- [ ] Os 5 serviços aparecem em **APM & Services → Services - OpenTelemetry**
      (`auth-service`, `flag-service`, `targeting-service`,
      `evaluation-service`, `analytics-service`).
- [ ] **Distributed tracing**: um trace de `GET /evaluate` mostra
      evaluation → flag → auth, evaluation → targeting → auth, Redis e
      evaluation → SQS → analytics (caminho completo em [OTEL.md](OTEL.md#caminho-de-uma-requisição-trace-distribuído)).
- [ ] **Service map** (entidade `evaluation-service` → Service map): os 5
      serviços conectados + Postgres, Redis, SQS e DynamoDB.

### 6. Evidências (relatório / vídeo)

1. Service map com os 5 serviços.
2. Trace distribuído de `GET /evaluate` aberto (waterfall com os spans de todos os serviços).
3. Resultado da 2ª query NRQL acima (prova de que o trace cruza os serviços).

## Troubleshooting

| Sintoma | Causa provável |
|---|---|
| `403 Forbidden` no log do Collector | Secret ausente/errado, chave do tipo *User* (`NRAK-...`) em vez de *License*, ou região errada (EU vs US) |
| Serviço não aparece no New Relic | Pod sem as env `OTEL_*` (ConfigMap) ou sem tráfego que não seja `/health` |
| `analytics-service` isolado no mapa | `traceparent` não chegou na mensagem SQS — conferir o span `publish` (PRODUCER) no evaluation |
| Traces quebrados em vários pedaços | Algum serviço sem propagação W3C (`OTEL_PROPAGATORS=tracecontext,baggage`) |
