# OpenTelemetry — Collector + instrumentação dos 5 microsserviços (Fase 4, Parte 2)

## Arquitetura

```
                     OTLP/HTTP :4318 (traces + métricas + logs)
 auth-service  ─┐
 flag-service  ─┤        ┌──────────────── otel-collector (DaemonSet, 1 por nó) ────────────────┐
 targeting-svc ─┼──────▶ │ receivers   otlp, filelog*, hostmetrics                              │
 evaluation-svc─┤        │ processors  memory_limiter → k8sattributes → resource → batch        │
 analytics-svc ─┘        │ exporters   traces  → debug + New Relic APM (OTLP) — ver APM.md      │
                         │             metrics → prometheus :8889 ◀── scrape (ServiceMonitor)   │
                         │             logs    → Loki /otlp                                     │
                         └──────────────────────────────────────────────────────────────────────┘
   * filelog = stdout de todos os OUTROS containers do cluster (os 5 serviços mandam logs via OTLP)
```

- **Um único ponto de entrada**: os serviços só conhecem o Collector
  (`http://otel-collector.monitoring.svc.cluster.local:4318`). Trocar/adicionar
  backend (ex: APM) é mudança só no Collector, sem tocar nas aplicações.
- **DaemonSet + `internalTrafficPolicy: Local`**: cada pod fala com o Collector
  do próprio nó (sem salto de rede entre nós); requisito do `k8sattributes`,
  que em DaemonSet só observa os pods do seu nó.
- **Processors**: `memory_limiter` (protege o Collector de OOM),
  `k8sattributes` (enriquece com namespace/pod/deployment/nó), `resource`
  (tags `deployment.environment=prod` e `k8s.cluster.name`), `batch`.
- **Logs sem duplicar**: os 5 serviços enviam os próprios logs via OTLP (com
  `trace_id`/`span_id` → correlação log ↔ trace no Grafana/APM); por isso os
  namespaces deles estão no `exclude` do filelog. O stdout continua igual
  (`kubectl logs` funciona como antes).

Config: [`argocd/applications-observability.yaml`](../argocd/applications-observability.yaml)
(Application `otel-collector`, chart `opentelemetry-collector` 0.174.0 / collector-contrib 0.161.0).

## Padrão de variáveis de ambiente (iguais nos 5 serviços)

| Variável | Onde | Valor |
|---|---|---|
| `OTEL_SERVICE_NAME` | ConfigMap | nome do serviço (`auth-service`, ...) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | ConfigMap | `http://otel-collector.monitoring.svc.cluster.local:4318` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | ConfigMap | `http/protobuf` |
| `OTEL_TRACES_SAMPLER` | ConfigMap | `parentbased_always_on` (100% — volume de lab) |
| `OTEL_METRIC_EXPORT_INTERVAL` | ConfigMap | `15000` (ms) |
| `OTEL_PROPAGATORS` | ConfigMap | `tracecontext,baggage` (W3C) |
| `OTEL_RESOURCE_ATTRIBUTES` | Deployment | `service.namespace=togglemaster,service.version=<image.tag>,k8s.pod.name,k8s.pod.ip,k8s.namespace.name,k8s.node.name` (via Downward API) |

Sem `OTEL_EXPORTER_OTLP_ENDPOINT` (dev local / testes unitários) os serviços
não exportam nada e se comportam exatamente como antes.
Para desligar a telemetria de um serviço sem rebuild: `OTEL_SDK_DISABLED=true`.

## Instrumentação por serviço

| Serviço | Linguagem | O que gera spans | Arquivos |
|---|---|---|---|
| auth-service | Go | HTTP server (`otelhttp`), queries Postgres (`otelsql`) | `telemetry.go`, `main.go`, `handlers.go` |
| evaluation-service | Go | HTTP server, chamadas HTTP p/ flag e targeting (`otelhttp.Transport`), Redis (`redisotel`), publish na SQS (span manual + `traceparent` nos MessageAttributes) | `telemetry.go`, `main.go`, `evaluator.go`, `handlers.go`, `sqs.go` |
| flag-service | Python | Flask, `requests` (→ auth), psycopg2 | `telemetry.py`, `gunicorn.conf.py` |
| targeting-service | Python | Flask, `requests` (→ auth), psycopg2 | `telemetry.py`, `gunicorn.conf.py` |
| analytics-service | Python | consumo da SQS (span CONSUMER continuando o trace do evaluation), boto3 (SQS/DynamoDB) | `telemetry.py`, `gunicorn.conf.py`, `app.py` |

- `telemetry.go` é idêntico nos 2 serviços Go; `telemetry.py` e
  `gunicorn.conf.py` são idênticos nos 3 serviços Python.
- **Go**: versões fixadas em otel `v1.28.0` / contrib `v0.53.0` — as últimas
  compatíveis com Go 1.21 (versão do template de CI em `infra-tc3`).
- **Python**: SDK `1.45.0` / instrumentações `0.66b0`. O SDK é iniciado **por
  worker** no hook `post_fork` do gunicorn (não pelo `opentelemetry-instrument`
  no master): assim cada worker tem seu `service.instance.id` e as métricas dos
  2 workers não colidem no Prometheus.
- `/health` é excluído dos traces/métricas (probes do k8s a cada 10-15s).

### Caminho de uma requisição (trace distribuído)

```
GET /evaluate (evaluation-service, SERVER)
├── Redis GET flag_info:<flag>                  (cache)
├── HTTP GET flag-service /flags/<flag>  ──▶ flag-service (SERVER)
│                                             ├── HTTP GET auth-service /validate ──▶ auth-service (SERVER) ── SELECT api_keys (postgres)
│                                             └── SELECT flags (postgres)
├── HTTP GET targeting-service /rules/<flag> ─▶ targeting-service (SERVER) ── (mesmo padrão: auth + postgres)
├── Redis SET flag_info:<flag>
└── <fila> publish (PRODUCER, SQS) ─ traceparent nos MessageAttributes
      └──▶ analytics-service: <fila> process (CONSUMER) ── DynamoDB PutItem, SQS DeleteMessage
```

Resultado: os 5 serviços aparecem conectados no Service Map do APM.

## Métricas geradas (nomes no Prometheus)

Os atributos de resource viram labels (`service_name`, `k8s_namespace_name`,
`k8s_pod_name`, ...) e o ServiceMonitor reescreve `namespace`/`pod` para os do
serviço de origem (senão viriam como `monitoring`/pod do Collector).

| Métrica | Origem |
|---|---|
| `http_server_duration_milliseconds_{count,sum,bucket}` | os 5 serviços (labels `http_method`, `http_status_code`, `service_name`) |
| `http_client_duration_milliseconds_*` | evaluation, flag, targeting (chamadas HTTP de saída) |
| `process_runtime_go_*` | runtime Go (goroutines, GC, heap) |
| `db_sql_*` | pool de conexões do auth-service |

PromQL úteis:

```promql
# Taxa de requisições por serviço (já usada no dashboard)
sum(rate(http_server_duration_milliseconds_count{namespace=~"auth-service|flag-service|targeting-service|evaluation-service|analytics-service"}[5m])) by (service_name)

# Latência p95 por serviço (ms)
histogram_quantile(0.95, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le, service_name))

# Taxa de erro 5xx (%) por serviço — base para o alerta (Parte 4)
100 * sum(rate(http_server_duration_milliseconds_count{http_status_code=~"5.."}[5m])) by (service_name)
    / sum(rate(http_server_duration_milliseconds_count[5m])) by (service_name)
```

> **Atenção (Parte 4/5 — cenário de incidente):** o `/validate` do
> auth-service responde **401** (não 5xx) para *qualquer* erro, inclusive banco
> fora do ar. Já flag/targeting respondem **503/504** quando o auth não
> responde, e o evaluation responde **502** quando o flag-service falha. Se o
> incidente for "derrubar o banco do flag-service", o 5xx aparece no
> flag-service e no evaluation-service.

## Logs no Loki

Os logs OTLP chegam com os labels `service_name`, `k8s_namespace_name`,
`k8s_pod_name` (etc.) e com `trace_id`/`span_id` como structured metadata.

```logql
{service_name="flag-service"}
{k8s_namespace_name="evaluation-service"} |= "Erro"
{service_name=~".+"} | trace_id="<trace id do APM>"
```

O nível (`severity`) vem do `logging` nos serviços Python; nos serviços Go
(que usam `log.Printf` sem nível) é inferido pelo texto
("Erro"/"Falha" → ERROR, "Aviso"/"Atenção" → WARN, resto → INFO).

## Parte 3 (APM): New Relic

Implementado: exporter `otlphttp/newrelic` no pipeline `traces`, com a license
key vinda de um Secret fora do Git. Passo a passo, validação e justificativa da
escolha (New Relic vs Datadog): **[APM.md](APM.md)**.

## Como validar no cluster (depois do sync do ArgoCD + deploy das imagens)

```bash
# 1. Collector rodando (1 pod por nó) e config aplicada
kubectl -n monitoring get ds otel-collector-agent
kubectl -n monitoring logs ds/otel-collector-agent | grep -i error

# 2. Gerar tráfego REAL. O ingress reescreve /evaluate/<x> -> /<x>, então o
#    endpoint fica /evaluate/evaluate. Não precisa de chave: o evaluation usa a
#    SERVICE_API_KEY dele para chamar flag/targeting (que validam no auth).
#    Mesmo com uma flag inexistente a requisição percorre evaluation -> flag ->
#    auth e evaluation -> targeting -> auth (resposta 200, result=false).
#    ATENÇÃO: o scripts/load-test.sh só chama /health, que é excluído da
#    telemetria — ele não popula o painel de req/s nem gera traces.
INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$INGRESS_HOST/evaluate/evaluate?user_id=u1&flag_name=demo"
hey -z 60s -c 10 "http://$INGRESS_HOST/evaluate/evaluate?user_id=u1&flag_name=demo"

# 3. Traces chegando (exporter debug imprime um resumo por lote)
kubectl -n monitoring logs ds/otel-collector-agent --since=2m | grep -E "Traces|spans"

# 4. Métricas expostas para o Prometheus
kubectl -n monitoring port-forward ds/otel-collector-agent 8889:8889 &
curl -s localhost:8889/metrics | grep http_server_duration_milliseconds_count | head

# 5. Prometheus raspando o target (Status > Targets: serviceMonitor/monitoring/otel-collector)
#    e Grafana > Explore > Loki: {service_name="evaluation-service"}
```
