# Pausar e retomar a infra (economia de créditos)

Procedimento para escalar a infra para baixo quando não estiver em uso (sem
destruir nada) e para trazer tudo de volta depois. Diferente de
[`RECREATE-INFRA.md`](RECREATE-INFRA.md), que é para reconstruir do zero —
aqui nada é apagado, só desligado temporariamente.

---

## Pausar (escalar para baixo)

```bash
export AWS_PROFILE=<nome-do-profile>

# Node group do EKS -> 0 nos (nao e possivel setar desired < min, entao os
# dois precisam ir junto)
aws eks update-nodegroup-config --cluster-name tech-challenge-prod-eks \
  --nodegroup-name tech-challenge-prod-node-group \
  --scaling-config minSize=0,maxSize=10,desiredSize=0 --region us-east-1

# RDS -> stopped (as 3 instancias, uma por servico)
for db in tech-challenge-prod-auth tech-challenge-prod-flag tech-challenge-prod-targeting; do
  aws rds stop-db-instance --db-instance-identifier "$db" --region us-east-1
done
```

**Alterar no repo** (`terraform/terraform.tfvars`) — evita que um
`terraform apply` futuro force o node group de volta ao mínimo configurado:

```diff
- eks_node_desired_size   = 4
- eks_node_min_size       = 2
+ eks_node_desired_size   = 0 # ignorado pelo lifecycle do node group; ajustado via AWS CLI
+ eks_node_min_size       = 0
```

```bash
git add terraform/terraform.tfvars
git commit -m "chore: escala node group do EKS para min=0 (economia de credito)"
git push origin main
```

### O que isso derruba
ArgoCD, Grafana, Loki, Prometheus e os 5 microsserviços rodam em cima desses
nós — tudo fica inacessível enquanto os nós estiverem em 0. Nada é perdido
(os Deployments/StatefulSets continuam existindo, só sem onde rodar), exceto
dados do Prometheus/Loki, que já rodam em `emptyDir` sem persistência.

### O que continua cobrando mesmo assim
- Control plane do EKS (~US$0,10/h, independe de quantidade de nós)
- 3 NAT Gateways (~US$0,045/h cada)
- ElastiCache Redis (não tem "stop", só destruir)
- Armazenamento do RDS (parar só economiza o compute)
- **A AWS reinicia o RDS sozinha depois de 7 dias parado** — se for ficar mais
  tempo que isso sem usar, repita o passo de parar o RDS (ou automatize com
  Lambda + EventBridge).

---

## Retomar (escalar de volta)

### 1. Esperar o RDS terminar de parar (se o status ainda for `stopping`)

```bash
for db in tech-challenge-prod-auth tech-challenge-prod-flag tech-challenge-prod-targeting; do
  aws rds wait db-instance-stopped --db-instance-identifier "$db" --region us-east-1
done
```

### 2. Religar o RDS (uns 5-10 min por instância, roda em paralelo)

```bash
for db in tech-challenge-prod-auth tech-challenge-prod-flag tech-challenge-prod-targeting; do
  aws rds start-db-instance --db-instance-identifier "$db" --region us-east-1
done
```

Endpoint/hostname não mudam ao parar/religar — os Secrets do Kubernetes
(`DATABASE_URL` etc.) continuam válidos, **não precisa recriar nada**.

### 3. Escalar o node group do EKS de volta (uns 2-3 min)

```bash
aws eks update-nodegroup-config --cluster-name tech-challenge-prod-eks \
  --nodegroup-name tech-challenge-prod-node-group \
  --scaling-config minSize=2,maxSize=10,desiredSize=4 --region us-east-1
```

### 4. Esperar os nós ficarem `Ready`

```bash
kubectl get nodes -w
```

### 5. Não precisa reaplicar nada no ArgoCD

Os Deployments/StatefulSets nunca saíram do cluster — só ficaram `Pending`
sem node pra rodar. Assim que os nós voltam, os pods agendam e sobem
sozinhos (o GitOps também faz self-heal de qualquer coisa que tiver ficado
torta). Só acompanhe:

```bash
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### 6. Validar (mesmas URLs de antes, nada muda)

```bash
INGRESS_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_HOST/auth/health"
```

**Alterar no repo** (`terraform/terraform.tfvars`) — restaurar os valores
originais, pra manter o IaC consistente com o estado real:

```diff
- eks_node_desired_size   = 0 # ignorado pelo lifecycle do node group; ajustado via AWS CLI
- eks_node_min_size       = 0
+ eks_node_desired_size   = 4
+ eks_node_min_size       = 2
```

```bash
git add terraform/terraform.tfvars
git commit -m "chore: restaura node group do EKS para min=2/desired=4"
git push origin main
```
