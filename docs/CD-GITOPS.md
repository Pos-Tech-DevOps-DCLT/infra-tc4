# CD — Atualização automática do GitOps

Documenta o **job 7 (`update-gitops`)** dos templates de pipeline, responsável
pelo elo final da entrega contínua: publicada a imagem no ECR, a nova tag é
escrita no repositório GitOps e o ArgoCD sincroniza o cluster sozinho.

---

## O fluxo ponta a ponta

```
 repositório do microsserviço            repositório GitOps (infra-tc4)          cluster EKS
┌──────────────────────────────┐        ┌──────────────────────────────┐        ┌──────────────┐
│ push na main                 │        │                              │        │              │
│   ↓                          │        │                              │        │              │
│ 1 testes unitários           │        │                              │        │              │
│ 2 lint (flake8 / golangci)   │        │                              │        │              │
│ 3 SCA (Trivy)                │        │                              │        │              │
│ 4 SAST (Horusec) ── bloqueia │        │                              │        │              │
│ 5 docker build               │        │                              │        │              │
│ 6 push ECR  ──── tag <sha7> ─┼───────▶│ charts/<svc>/values.yaml     │        │              │
│ 7 update-gitops ─────────────┼───────▶│   image.tag: "<sha7>"        │        │              │
└──────────────────────────────┘ commit └──────────────┬───────────────┘        │              │
                                                       │ ArgoCD detecta (~3min) │              │
                                                       └───────────────────────▶│ rollout novo │
                                                              auto-sync         └──────────────┘
```

A tag da imagem é sempre o **short SHA do commit** (7 caracteres) — a mesma que
o job 6 publicou no ECR. Nunca `latest`: tag imutável é o que permite saber
exatamente qual commit está rodando em produção e voltar atrás com segurança.

---

## Pré-requisito: o secret `GITOPS_TOKEN`

O job roda no repositório do microsserviço, mas precisa **commitar em outro
repositório** (`infra-tc4`). O `GITHUB_TOKEN` padrão não serve — ele só tem
permissão no repositório que disparou o run. É preciso um PAT.

### Como criar

1. GitHub → **Settings** (da sua conta) → **Developer settings** →
   **Personal access tokens** → **Fine-grained tokens** → *Generate new token*
2. Preencha:
   - **Resource owner**: `Pos-Tech-DevOps-DCLT`
   - **Repository access**: *Only select repositories* → `infra-tc4`
   - **Permissions** → *Repository permissions* → **Contents: Read and write**
     (só isso — nada além)
   - **Expiration**: a menor data que cubra a entrega
3. Copie o token (só aparece uma vez).

### Onde salvar

**Preferido — secret de organização** (vale para os 5 repositórios de uma vez):

> Organização `Pos-Tech-DevOps-DCLT` → **Settings** → **Secrets and variables** →
> **Actions** → *New organization secret*
> Nome: `GITOPS_TOKEN` · Repository access: os 5 repositórios `*-tc3`

**Alternativa — secret por repositório**, caso não tenha permissão de admin na
organização. Repetir em cada um dos 5:

> Repositório → **Settings** → **Secrets and variables** → **Actions** →
> *New repository secret* → Nome: `GITOPS_TOKEN`

Os workflows dos microsserviços já usam `secrets: inherit`, então o secret chega
ao template reutilizável sem nenhuma alteração adicional.

---

## O que o job faz, passo a passo

| Passo | O que faz | Falha quando |
|:--|:--|:--|
| Validar secret | Confere que `GITOPS_TOKEN` existe | Secret ausente ou vazio |
| Checkout GitOps | Clona `infra-tc4` em `./gitops` com histórico completo | Token sem permissão de leitura |
| Calcular tag | `github.sha` → short SHA de 7 caracteres | — |
| Atualizar values | Reescreve `image.tag` em `charts/<svc>/values.yaml` | Chart não existe, ou `tag:` não é única no arquivo |
| Commit e push | Commita como `github-actions[bot]` e envia para a `main` | 5 tentativas de push rejeitadas |
| Resumo | Publica a tabela antes/depois no Job Summary | — |

### Decisões de implementação

**Edição com `sed`, não com `yq -i`.** O `yq -i` reescreve o YAML inteiro e
apaga as linhas em branco do arquivo — o commit do bot viria com dezenas de
linhas alteradas em vez de uma. O `sed` altera só a linha da tag. Para não abrir
mão da segurança, o passo tem duas travas:

- **antes**: aborta se a chave `tag:` não aparecer exatamente uma vez no arquivo
  (evita acertar a linha errada se o chart mudar de forma);
- **depois**: relê o arquivo com `yq` e confirma que `.image.tag` tem o valor
  esperado — prova que o YAML continua válido e que o `sed` acertou o alvo.

**A tag é sempre escrita entre aspas.** Um short SHA como `1234567` seria lido
pelo YAML como número, e `1e50000` como float — o manifesto quebraria.

**Retry com rebase no push.** Os 5 microsserviços podem terminar o CI ao mesmo
tempo e disputar a mesma branch. O `concurrency` do GitHub Actions só serializa
dentro do mesmo repositório, então não resolve corrida entre repositórios
diferentes. O push tenta 5 vezes, com `git pull --rebase` a cada rejeição.

**Commit com `[skip ci]`.** Higiene: garante que o commit do bot nunca dispare
uma pipeline, hoje ou quando o `infra-tc4` ganhar workflows de `push`.

**Idempotência.** Se a tag no `values.yaml` já for a nova, o job não commita e
termina com sucesso — reexecutar o run não gera commit vazio.

---

## Como testar

### Sem cluster (valida do commit ao GitOps)

1. Qualquer commit na `main` de um dos 5 repositórios de microsserviço.
2. Acompanhe o run em **Actions** → job **7 · Atualizar GitOps (CD)**.
3. Confirme no `infra-tc4` um commit novo do `github-actions[bot]`, com a
   mensagem `chore(<serviço>): atualiza image.tag para <sha7>` e diff de uma
   linha em `charts/<serviço>/values.yaml`.

O Job Summary do run mostra a tag anterior, a nova e a imagem completa.

### Com cluster (ponta a ponta, para a demonstração)

4. No ArgoCD, a Application do serviço vai de `Synced` para **`OutOfSync`** e,
   em até ~3 minutos, volta para `Synced` sozinha (`syncPolicy: automated`).
5. Confirme a imagem que subiu:

```bash
kubectl get deploy <serviço> -n <serviço> \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Para não esperar o polling na hora da demo, force a detecção com
**Refresh** na Application (ou `argocd app get <serviço> --refresh`).

---

## Problemas comuns

| Sintoma | Causa | Solução |
|:--|:--|:--|
| `Secret GITOPS_TOKEN ausente` | Secret não criado, ou a organização não liberou o repositório | Ver a seção do PAT acima |
| `remote: Permission to ... denied` | PAT sem **Contents: Read and write**, ou expirado | Gerar novo PAT e atualizar o secret |
| `Chart nao encontrado` | Nome em `inputs.project` diferente da pasta em `charts/` | Alinhar o `project` do workflow do microsserviço com o nome do chart |
| `values.yaml inesperado` | O chart passou a ter mais de uma chave `tag:` | Ajustar o `sed` do job 7 para ancorar no bloco `image:` |
| Job 7 não executou | Push fora da `main`, ou o job 6 falhou | O job só roda em `push` na `main`, e depende do `push-ecr` |
| ArgoCD não sincronizou | Polling ainda não rodou, ou auto-sync desligado | **Refresh** na Application; conferir `syncPolicy.automated` |
| Pod continua na imagem antiga | Chart com imagem fixa no template | O `deployment.yaml` precisa usar `{{ .Values.image.repository }}:{{ .Values.image.tag }}` |

---

## Arquivos envolvidos

| Arquivo | Papel |
|:--|:--|
| `.github/workflows/ci-cd-python-template.yaml` | Job 7 — flag, targeting e analytics |
| `.github/workflows/ci-cd-go-template.yaml` | Job 7 — auth e evaluation |
| `charts/<serviço>/values.yaml` | Alvo do bump (`image.tag`) |
| `charts/<serviço>/templates/deployment.yaml` | Consome `.Values.image` |
| `argocd/applications.yaml` | Applications com `syncPolicy: automated` |
