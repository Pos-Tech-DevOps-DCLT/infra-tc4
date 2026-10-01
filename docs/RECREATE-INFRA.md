# Recriar toda a infraestrutura do zero

Runbook para reconstruir, numa conta AWS nova (ou do zero na mesma), tudo que
este repositório provisiona: Terraform (VPC/EKS/RDS/ElastiCache/ECR/SQS/
DynamoDB/IRSA), ArgoCD, a stack de observabilidade (Prometheus, Grafana,
Loki, OTel Collector) e os 5 microsserviços.

Serve tanto para você seguir manualmente quanto para colar numa conversa com
o Claude pedindo para refazer a estrutura — ele tem contexto suficiente aqui
para executar os passos sozinho.

---

## 0. Pré-requisitos

**Ferramentas locais:** `terraform`, `aws` CLI, `kubectl`, `helm`, `argocd`
(CLI), `docker`, `git`, `python3`.

**Conta AWS:** credenciais com permissão para criar IAM roles livremente
(`iam:CreateRole`, `iam:CreatePolicy`, `iam:AttachRolePolicy` etc.). **Contas
AWS Academy Learner Lab não servem** — elas bloqueiam `iam:CreateRole` e só
permitem usar roles pré-criadas pela Academy, o que exige um workaround
diferente (ver nota no final). Uma conta free tier normal (usuário IAM com
policy administrativa) funciona de ponta a ponta sem ajuste nenhum.

**Repo:** clone de `https://github.com/Pos-Tech-DevOps-DCLT/infra-tc4.git` —
este documento assume que os comandos rodam a partir da raiz dele, e que o
Terraform roda a partir de `terraform/`.

---

## 1. Credenciais AWS

Configure um profile apontando para a conta alvo:

```bash
aws configure --profile <nome-do-profile>
# ou cole access key / secret key / session token em ~/.aws/credentials
```

Confirme a identidade e anote o **Account ID** (vai ser usado em vários
lugares abaixo):

```bash
aws sts get-caller-identity --profile <nome-do-profile>
```

---

## 2. Backend do Terraform (state remoto)

Cada conta AWS precisa do próprio bucket S3 + tabela DynamoDB — eles não
existem por padrão numa conta nova.

```bash
export AWS_PROFILE=<nome-do-profile>
export AWS_DEFAULT_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="tech-challenge-terraform-state-${ACCOUNT_ID}"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

aws dynamodb wait table-exists --table-name terraform-state-lock --region us-east-1
```

Edite `terraform/backend.tf` e troque o `bucket` para o valor de `$BUCKET`
acima. Commitar essa mudança no repo é o esperado (é assim que o resto do
time sabe qual conta/bucket está em uso).

---

## 3. Provisionar a infraestrutura

```bash
cd terraform
terraform init -reconfigure
terraform plan -out=tfplan   # confira: só "to add", zero "to destroy"
terraform apply tfplan
```

Leva de 15 a 20 minutos (o cluster EKS sozinho leva uns 10-12 min, o node
group mais 2-3 min). Ao final, confira os outputs — principalmente
`eks_cluster_name`, `ecr_repository_urls`, `rds_secret_arns`,
`elasticache_secret_arn`, `sqs_queue_url`, `dynamodb_table_name` e
`irsa_*_role_arn` — vão ser usados nos passos seguintes.

**Se a conta não permitir `iam:CreateRole`** (Learner Lab): não dá para usar
o `terraform apply` direto. É preciso adaptar `modules/eks` para usar roles
pré-existentes via `data "aws_iam_role"` em vez de criar novas, e isso tem
limitações sérias de portabilidade (nomes de role são únicos por sessão de
lab) — peça ajuda ao Claude explicando que é uma conta restrita antes de
tentar.

---

## 4. Configurar o kubectl

```bash
aws eks update-kubeconfig --name tech-challenge-prod-eks --region us-east-1 --profile <nome-do-profile>
kubectl get nodes
```

---

## 5. Ferramentas de cluster (metrics-server, ingress-nginx, KEDA)

Necessário antes da `infrastructure` Application do ArgoCD ficar saudável
(ela usa `ingressClassName: nginx`) e antes de qualquer `ScaledObject` do
KEDA funcionar.

```bash
KEDA_ROLE_ARN=$(cd terraform && terraform output -raw irsa_keda_role_arn)
./scripts/helm-install.sh "$KEDA_ROLE_ARN"
```

---

## 6. Instalar o ArgoCD

```bash
./scripts/install-argocd.sh
```

O script já inclui os limites de memória corrigidos (ver "Armadilhas"
abaixo). Ele imprime a URL (LoadBalancer) e a senha inicial de `admin` ao
final — guarde os dois. Essa senha **não** troca sozinha (ArgoCD não é
auto-gerenciado aqui, foi instalado via `helm install` direto, não como uma
Application contínua).

---

## 7. Credenciais fixas do Grafana — fazer ANTES do passo 8

O chart `kube-prometheus-stack` gera uma senha de admin do Grafana
**aleatória a cada `helm template`** se você não fixar uma. Como o ArgoCD não
guarda estado de release do Helm (diferente de rodar `helm upgrade` manual),
toda sincronização re-renderiza o chart do zero — e sem esse passo a senha
trocaria a cada sync.

```bash
PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic prometheus-grafana-admin -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$PASS"
echo "Senha do Grafana: $PASS"   # guarde isso
```

(`argocd/applications-observability.yaml` já referencia esse Secret via
`grafana.admin.existingSecret: prometheus-grafana-admin` — só precisa
existir no cluster antes do sync.)

---

## 8. Stack de observabilidade (Prometheus, Loki, OTel Collector, dashboard)

```bash
kubectl apply -f argocd/applications-observability.yaml
```

Acompanhe com `kubectl get applications -n argocd` até os 4 apps
(`kube-prometheus-stack`, `loki`, `otel-collector`, `observability-extras`)
ficarem `Synced`/`Healthy`. O Prometheus Operator demora para criar o
`StatefulSet` do Prometheus/Alertmanager (até 1 min depois dos CRDs
existirem) — se ele nunca aparecer, veja a armadilha #3 abaixo.

Pegue a URL e senha do Grafana:

```bash
kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl get secret prometheus-grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

---

## 9. Publicar as imagens dos microsserviços no ECR

Os repositórios ECR (`tech-challenge-prod/<serviço>`) já existem (criados
pelo Terraform), mas vazios — nada é publicado automaticamente pelo
`terraform apply`.

Se tiver os 5 repos de microsserviço clonados localmente
(`auth-service-tc4`, `flag-service-tc4`, `targeting-service-tc4`,
`evaluation-service-tc4`, `analytics-service-tc4`, um nível acima deste
repo):

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd ..   # para o diretório que contém os 5 repos de microsservico + infra-tc4

for svc_dir in auth-service-tc4:auth-service flag-service-tc4:flag-service \
               targeting-service-tc4:targeting-service \
               evaluation-service-tc4:evaluation-service \
               analytics-service-tc4:analytics-service; do
  dir="${svc_dir%%:*}"; name="${svc_dir##*:}"
  tag=$(cd "$dir" && git rev-parse --short HEAD)
  docker build -t "${name}:${tag}" "$dir"
  infra-tc4/scripts/publish-images.sh us-east-1 "$ACCOUNT_ID" "$tag"
done
```

Depois atualize `repository`/`tag` em `charts/<serviço>/values.yaml` para o
novo `$ACCOUNT_ID` e tag publicada, e commite.

**Atenção a dois bugs conhecidos** nos Dockerfiles do `targeting-service-tc4`
e `analytics-service-tc4` (não fazem parte deste repo, então não são
corrigidos automaticamente se você clonar esses repos de novo):

1. Copiam os pacotes Python para `/root/.local` mas rodam como usuário
   não-root → `Permission denied` ao executar o `gunicorn`. Fix: copiar com
   `--chown=appuser:appgroup` para `/home/appuser/.local` (mesmo padrão já
   usado no `flag-service-tc4/Dockerfile`).
2. `requirements.txt` sem pin de `Werkzeug` → instala a versão mais nova do
   PyPI, incompatível com `Flask==2.2.2` (`ImportError: url_quote`). Fix:
   adicionar `Werkzeug==2.2.3` (mesma versão que o `flag-service-tc4` já
   fixa).

Se esses repos ainda não tiverem esse fix commitado, aplique localmente,
rebuilde e publique com uma tag nova antes de seguir.

Alternativa: se as pipelines de CI/CD dos 5 microsserviços já estiverem
configuradas com o secret `GITOPS_TOKEN` e credenciais AWS da conta nova
(ver `docs/CD-GITOPS.md`), um `git push` em cada repo faz esse trabalho
sozinho.

---

## 10. Secrets dos microsserviços (não ficam no Git)

Cada serviço espera um Secret do Kubernetes (`envFrom.secretRef`) com
credenciais reais, criado fora do GitOps por segurança:

| Secret | Namespace | Chaves |
|---|---|---|
| `auth-service-secret` | `auth-service` | `DATABASE_URL`, `MASTER_KEY` |
| `flag-service-secret` | `flag-service` | `DATABASE_URL` |
| `targeting-service-secret` | `targeting-service` | `DATABASE_URL` |
| `evaluation-service-secret` | `evaluation-service` | `REDIS_URL`, `SERVICE_API_KEY` |
| `analytics-service-secret` | — (não precisa; usa IRSA) | — |

`DATABASE_URL` é `postgresql://<user>:<pass>@<host>:<port>/<dbname>` com os
valores do Secrets Manager (`terraform output -json rds_secret_arns`).
`REDIS_URL` é `rediss://:<auth_token>@<primary_endpoint>:<port>` (`rediss://`
com dois "s" — o ElastiCache aqui tem `transit_encryption_enabled = true`).
`MASTER_KEY` e `SERVICE_API_KEY` são valores inventados por você (strings
aleatórias fortes), usados internamente por cada serviço.

```bash
# exemplo para um serviço — repetir para os outros, trocando o nome/namespace
kubectl create secret generic auth-service-secret -n auth-service \
  --from-literal=DATABASE_URL='postgresql://user:pass@host:5432/authdb' \
  --from-literal=MASTER_KEY="$(openssl rand -base64 32)"
```

---

## 11. Subir os microsserviços via GitOps

```bash
kubectl apply -f argocd/repo.yaml
kubectl apply -f argocd/applications.yaml
```

Acompanhe com `kubectl get applications -n argocd` até os 6 apps
(`infrastructure` + 5 serviços) ficarem `Synced`/`Healthy`, e
`kubectl get pods -n <namespace-do-servico>` até os pods ficarem `1/1
Running`.

---

## 12. Validar tudo

```bash
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
# as 10 Applications (5 servicos + infrastructure + 4 de observabilidade) devem estar Synced/Healthy

INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for path in auth flags targeting evaluate analytics; do
  curl -s -o /dev/null -w "/$path/health -> %{http_code}\n" "http://$INGRESS_HOST/$path/health"
done
```

---

## Armadilhas conhecidas

1. **CRDs do Prometheus Operator estouram o limite de annotation do
   client-side apply** (`metadata.annotations: Too long: may not be more
   than 262144 bytes`). Fix: a Application `kube-prometheus-stack` já tem
   `syncOptions: [ServerSideApply=true]` em
   `argocd/applications-observability.yaml` — não remova.
2. **O Prometheus Operator sobe antes dos CRDs existirem** na primeira vez
   (ele faz discovery da API só no boot) e fica sem reconciliar `Prometheus`/
   `Alertmanager`. Sintoma: `kubectl get prometheus -n monitoring` mostra o
   recurso criado mas nenhum `StatefulSet` aparece. Fix: `kubectl rollout
   restart deployment prometheus-kube-prometheus-operator -n monitoring`.
3. **`argocd-application-controller` entra em `OOMKilled`/`CrashLoopBackOff`**
   sincronizando o `kube-prometheus-stack` (gera muitos recursos). O script
   `install-argocd.sh` já sobe com 2Gi de limite — se ainda acontecer, suba
   mais (`kubectl -n argocd patch statefulset argocd-application-controller
   ...`).
4. **Grafana também toma `OOMKilled`** com o limite de memória baixo demais
   sob uso normal do dashboard (múltiplos painéis concorrentes). O valor
   atual em `applications-observability.yaml` é 512Mi — se voltar a
   acontecer, suba mais.
5. **Sem EBS CSI driver no cluster** (omitido de propósito — workloads
   desenhados para serem stateless). Prometheus, Alertmanager e Loki rodam
   em `emptyDir`: funcional, mas **dados somem se o pod reiniciar**. O chart
   do Loki em particular não cai para `emptyDir` sozinho quando
   `persistence.enabled: false` — por isso os valores incluem
   `extraVolumes`/`extraVolumeMounts` manuais apontando um emptyDir para
   `/var/loki`.
6. **IDs de conta AWS hardcoded** — ao trocar de conta, verifique
   `charts/*/values.yaml` (campo `image.repository`),
   `charts/evaluation-service/templates/serviceaccount.yaml` e
   `charts/analytics-service/templates/serviceaccount.yaml` (ARN da IRSA
   role) e `charts/*/templates/configmap.yaml` (`AWS_SQS_URL`) — nenhum
   desses é parametrizado via `values.yaml`, são strings fixas que precisam
   ser atualizadas manualmente a cada nova conta.
7. **Cache do ArgoCD pode mentir.** `argocd app diff`/`get` às vezes mostra
   "sem diferença" mesmo com mudança pendente real, se o controller não
   atualizou o cache de estado do cluster. Use `argocd app get <nome>
   --hard-refresh` para forçar recálculo antes de confiar num "sem diff".

---

## Onde encontrar credenciais depois

- **ArgoCD:** `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d` (apague esse secret depois do primeiro login, por boa prática — a senha continua funcionando mesmo depois de apagado, ele é só a cópia em texto puro).
- **Grafana:** `kubectl get secret prometheus-grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d`
- **RDS / ElastiCache:** AWS Secrets Manager — `terraform output -json rds_secret_arns` / `terraform output -raw elasticache_secret_arn`.
