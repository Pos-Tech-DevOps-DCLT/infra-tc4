# Upgrade de versão do EKS

Runbook para subir a versão do Kubernetes do cluster EKS (`tech-challenge-prod-eks`)
de forma manual e segura, uma versão minor por vez.

---

## Regra da AWS: upgrade sempre sequencial

O EKS **não permite pular versões minor**. Para ir de `1.31` para `1.36`, o
caminho obrigatório é:

```
1.31 → 1.32 → 1.33 → 1.34 → 1.35 → 1.36
```

Cada seta acima é uma execução completa do procedimento abaixo. Não dá para
editar `eks_cluster_version` direto para `1.36` — o `terraform apply` falha se
a versão pedida não for exatamente uma minor à frente da atual.

Antes de começar, confira quais versões o EKS realmente suporta na região:

```bash
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[].clusterVersion' --output table
```

---

## Pré-requisitos

- `terraform`, `aws` CLI e `kubectl` instalados e configurados (ver
  [README.md](../README.md), Parte 1 e 2).
- `kubectl` apontando para o cluster:
  ```bash
  aws eks update-kubeconfig --region us-east-1 --name tech-challenge-prod-eks
  ```
- Working tree do `infra-tc4` limpo (`git status`) antes de começar.
- O node group precisa ter `version = var.cluster_version` no recurso
  `aws_eks_node_group.main` (`terraform/modules/eks/main.tf`). Sem isso, o
  Terraform sobe a versão do control plane mas os nós ficam presos na versão
  antiga — é preciso checar essa linha existe antes do primeiro upgrade.

---

## Procedimento (repita para cada versão)

### 1. Editar a versão alvo

Em `terraform/terraform.tfvars`, suba **uma única minor version**:

```diff
- eks_cluster_version     = "1.31"
+ eks_cluster_version     = "1.32"
```

### 2. Gerar e revisar o plano

```bash
cd terraform
terraform plan -out=tfplan_upgrade
```

O plano esperado é pequeno e **sem nenhum destroy**:

- `module.eks.aws_eks_cluster.main` — `version` muda in-place.
- `module.eks.aws_eks_node_group.main` — `version` muda in-place.
- `module.eks.aws_iam_openid_connect_provider.eks` — `thumbprint_list`
  recalculado (o certificado TLS do endpoint OIDC é reobtido; isso é
  cosmético, não muda a trust relationship).
- 2-3 `aws_iam_role` do módulo IRSA (`evaluation_service`, `analytics_service`,
  `keda`) aparecem como "updated in-place" só porque dependem do provider OIDC
  acima — o conteúdo final da policy não muda.

Se aparecer qualquer `force replacement` ou `destroy` em
`aws_eks_cluster.main`, **pare e não aplique** — algo está errado (ex.: mudança
de nome, região ou atributo imutável do cluster).

### 3. Checar a cota de vCPU antes de aplicar

O upgrade do node group (passo seguinte) faz um **rolling replace**: para cada
nó antigo removido, a AWS primeiro **lança um nó novo extra** (surge) antes de
terminar o antigo — por um instante, o número de instâncias é
`desired_size + 1`. Se a conta estiver com a cota de vCPU on-demand já no
limite com `desired_size` nós, esse nó extra não consegue nascer e o upgrade
do node group falha (`NodeCreationFailure`).

Confira a cota e o consumo atual antes de aplicar:

```bash
# Cota de vCPU on-demand para a família de instância usada (ex.: t3.micro = "Standard")
aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-1216C47A --region us-east-1 --query 'Quota.Value'

# vCPU já em uso = (nº de nós) × (vCPU por instância). t3.micro = 2 vCPU.
kubectl get nodes --no-headers | wc -l
```

Se `desired_size × vCPU_por_nó + vCPU_por_nó` (ou seja, com +1 nó de folga)
ultrapassar a cota, **não dá pra aplicar direto** — pule para a seção
[Quando a cota de vCPU trava o upgrade do node group](#quando-a-cota-de-vcpu-trava-o-upgrade-do-node-group)
antes de continuar.

### 4. Aplicar

```bash
terraform apply tfplan_upgrade
```

Isso dispara dois processos sequenciais dentro da mesma chamada:

1. **Upgrade do control plane** — a AWS atualiza a versão do control plane
   gerenciado. Leva tipicamente **10-15 minutos**. O comando fica bloqueado
   até isso terminar.
2. **Upgrade do node group** — depois que o control plane termina, o EKS
   substitui os nós um de cada vez (`update_config.max_unavailable = 1`, já
   configurado no módulo), lançando instâncias com a AMI da nova versão e
   drenando/terminando as antigas. Com 8 nós isso leva mais **10-20 minutos**.

Total por versão: normalmente **20-35 minutos**. Rode em background se for
usar o terminal para outra coisa:

```bash
terraform apply tfplan_upgrade > /tmp/tf_upgrade.log 2>&1 &
```

Se o passo 2 (node group) falhar por `NodeCreationFailure` /
`VcpuLimitExceeded` mesmo depois de checar a cota (ex.: outra coisa consumiu
vCPU nesse meio tempo), **o control plane já terá sido atualizado com
sucesso** — não precisa refazer aquela parte. Vá direto para
[Quando a cota de vCPU trava o upgrade do node group](#quando-a-cota-de-vcpu-trava-o-upgrade-do-node-group).

### 5. Verificar

```bash
# Control plane na versão nova e ACTIVE
aws eks describe-cluster --name tech-challenge-prod-eks --region us-east-1 \
  --query 'cluster.{version:version,status:status}'

# Todos os nós Ready na versão nova
kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,STATUS:.status.conditions[-1].type'

# Nenhuma Application do ArgoCD degradada pela troca de nós
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Só avance para a próxima versão depois que:
- `describe-cluster` mostrar a versão nova com `status: ACTIVE`;
- todos os nós mostrarem o `kubeletVersion` novo e `Ready`;
- todas as Applications do ArgoCD voltarem a `Synced` / `Healthy`.

### 6. Commitar

```bash
git add terraform/terraform.tfvars
git commit -m "chore(eks): upgrade cluster to 1.32

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push origin main
```

Um commit por versão dá um histórico claro de quando cada upgrade aconteceu —
útil se precisar correlacionar com algum incidente depois.

### 7. Repetir

Volte ao passo 1 com a próxima minor version, até chegar na versão desejada.

---

## Quando a cota de vCPU trava o upgrade do node group

Situação real encontrada no upgrade `1.31 → 1.32` desta conta: cluster com
`desired_size = 8` nós `t3.micro` (2 vCPU cada) = **16 vCPU**, exatamente igual
à cota on-demand da conta para essa família de instância. O node group nunca
consegue subir de versão sozinho nessa condição, porque o nó surge (o 9º)
nunca nasce.

Sintoma no `terraform apply`:

```
Error: waiting for EKS Node Group ... version update: unexpected state 'Failed',
wanted target 'Successful'. last error: : NodeCreationFailure: Couldn't proceed
with upgrade process as new nodes are not joining node group ...
```

E na ASG:

```bash
ASG=$(aws eks describe-nodegroup --cluster-name tech-challenge-prod-eks \
  --nodegroup-name tech-challenge-prod-node-group --region us-east-1 \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)

aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
  --region us-east-1 --max-items 3 \
  --query 'Activities[].StatusMessage' --output text
# → "Could not launch On-Demand Instances. VcpuLimitExceeded ..."
```

Duas saídas possíveis: pedir aumento de cota (correto a longo prazo, mas não é
instantâneo) ou abrir espaço temporariamente reduzindo `desired_size` antes do
upgrade. O passo a passo abaixo é o da segunda opção — foi o caminho usado
nesta conta.

### Passo 0 — importante: reconciliar o state se o apply já falhou

Quando o `terraform apply` falha *depois* de a AWS aceitar o pedido de update
do node group, o Terraform grava `version = "<versão nova>"` no state mesmo
tendo falhado — porque a chamada de API que inicia o update teve sucesso, só o
resultado final (`Successful`/`Failed`) é que veio negativo depois. Isso deixa
o state **mentindo**: ele diz que o node group já está na versão nova, mas a
AWS reverteu para a versão antiga.

Se isso acontecer, rode um refresh antes de continuar — senão o próximo
`terraform plan` não vai mostrar nenhuma mudança pendente (porque o state já
"acha" que terminou) e você vai achar que não há nada para corrigir:

```bash
terraform apply -refresh-only -auto-approve

# confirme que voltou para a versão real (antiga)
terraform state show module.eks.aws_eks_node_group.main | grep version
```

### Passo 1 — calcular quanto reduzir

Precisa sobrar pelo menos 1 instância de vCPU de folga em relação à cota, para
o nó surge nascer. Com cota de 16 vCPU e `t3.micro` (2 vCPU):

| `desired_size` durante o upgrade | vCPU em uso (steady) | + 1 surge | Cabe na cota de 16? |
|---|---|---|---|
| 8 (original) | 16 | 18 | ❌ |
| 7 | 14 | 16 | ✅ (exatamente no limite) |
| 6 | 12 | 14 | ✅ (folga confortável) |

Reduzir para `6` foi a escolha feita aqui, por dar folga em vez de ficar
exatamente no limite.

### Passo 2 — reduzir o node group

O `desired_size` é gerenciado fora do Terraform (o módulo tem
`lifecycle { ignore_changes = [scaling_config[0].desired_size] }` de propósito,
para não brigar com scaling manual). Use a CLI direto:

```bash
aws eks update-nodegroup-config \
  --cluster-name tech-challenge-prod-eks \
  --nodegroup-name tech-challenge-prod-node-group \
  --scaling-config minSize=2,maxSize=10,desiredSize=6 \
  --region us-east-1
```

Acompanhe até os nós sumirem (drena e termina 2 instâncias — leva alguns
minutos, a maior parte é o lifecycle hook da AWS esperando o dreno):

```bash
watch -n 15 'kubectl get nodes | wc -l'
```

**Efeito colateral esperado:** com menos nós, alguns pods de aplicação podem
ficar `Pending` temporariamente (menos slots de pod disponíveis — cada
`t3.micro` só aceita 4 pods pelo limite de ENI). Isso é esperado e se resolve
sozinho no passo 5, quando a capacidade volta a 8 nós. Não é motivo para
abortar o procedimento.

### Passo 3 — rodar o upgrade do node group

Com o control plane já na versão nova (se este for um retry do passo 4 da
seção anterior) ou seguindo o fluxo normal, gere e aplique o plano — agora com
folga de vCPU:

```bash
terraform plan -out=tfplan_upgrade_nodes
terraform apply tfplan_upgrade_nodes
```

O plano nesse ponto deve mostrar só a mudança de `version` do
`aws_eks_node_group.main` (o control plane já está na versão alvo, não
aparece de novo). Leva **15-20 minutos** para os 6 nós serem substituídos um a
um.

### Passo 4 — verificar a versão dos nós

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion'
```

Todos devem mostrar a versão nova antes de seguir.

### Passo 5 — voltar a capacidade ao normal

Escalar de volta para 8 nós, agora todos já na versão nova — isso **não**
precisa de folga extra de vCPU porque não é uma troca de versão, é só scale-out
puro (sem nó surge):

```bash
aws eks update-nodegroup-config \
  --cluster-name tech-challenge-prod-eks \
  --nodegroup-name tech-challenge-prod-node-group \
  --scaling-config minSize=2,maxSize=10,desiredSize=8 \
  --region us-east-1
```

Confirme que os pods `Pending` do passo 2 se resolveram sozinhos:

```bash
kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed | grep -v Running
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Depois disso, volte ao fluxo normal (passo 6 — commitar — da seção anterior) e
siga para a próxima minor version.

---

## Sequência completa para ir de 1.31 até 1.36

| Passo | De → Para | Observação |
|---|---|---|
| 1 | 1.31 → 1.32 | |
| 2 | 1.32 → 1.33 | |
| 3 | 1.33 → 1.34 | |
| 4 | 1.34 → 1.35 | |
| 5 | 1.35 → 1.36 | |

Cinco execuções completas do procedimento acima. Tempo total estimado:
**2 a 3 horas**, a maior parte apenas esperando a AWS.

---

## Problemas comuns

| Sintoma | Causa | Solução |
|:--|:--|:--|
| `terraform apply` recusa a versão | Pulou mais de uma minor version | Volte para a próxima versão sequencial |
| Node group trava em `UPDATING` por muito tempo | Pods com `PodDisruptionBudget` restritivo, ou nó sem capacidade para receber os pods drenados | `kubectl get pdb -A`; se for capacidade, ver a seção [Quando a cota de vCPU trava o upgrade do node group](#quando-a-cota-de-vcpu-trava-o-upgrade-do-node-group) |
| `NodeCreationFailure` / `VcpuLimitExceeded` durante a substituição dos nós | Cota de vCPU on-demand da conta é menor que o necessário para ter um nó extra temporário (surge) durante o rolling update | Seguir a seção [Quando a cota de vCPU trava o upgrade do node group](#quando-a-cota-de-vcpu-trava-o-upgrade-do-node-group) — reduzir `desired_size` temporariamente, ou pedir aumento de cota em Service Quotas → EC2 → "Running On-Demand Standard instances" |
| `terraform plan` não mostra nenhuma mudança pendente, mas os nós continuam na versão antiga | O `apply` anterior falhou depois de a AWS aceitar o update — o state ficou com a versão nova gravada mesmo o resultado real tendo sido `Failed` | `terraform apply -refresh-only -auto-approve` para reconciliar o state com a realidade antes de tentar de novo (ver Passo 0 da seção de cota de vCPU) |
| Pods de aplicação ficam `Pending` durante a troca de nós | Cluster já estava no limite de capacidade (pods por nó, ou vCPU da conta) antes do upgrade | Ver [README.md](../README.md) — cada `t3.micro` só aceita 4 pods (limite de ENI); considerar remover cargas não essenciais (ex. KEDA) antes de upgrades |
| Applications do ArgoCD ficam `Degraded` durante a troca de nós | Esperado brevemente enquanto os pods são reagendados nos nós novos | Aguardar o rolling update terminar; se não se recuperar sozinho, `kubectl get pods -A` para achar o pod preso |
