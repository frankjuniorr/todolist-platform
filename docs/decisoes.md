# Decisões de arquitetura

Cada decisão relevante está registrada como um ADR em `docs/adr/`, no formato
**contexto / decisão / consequências / alternativas descartadas**. Esta página é
o índice comentado.

O que separa um ADR útil de um parágrafo de README é a última seção: **o que foi
descartado e por quê**. Uma decisão sem alternativa considerada não é uma
decisão, é um default.

---

## 0001 — Argo CD como motor de GitOps

> `docs/adr/0001-argo-cd.md`

Argo CD e Flux resolvem o mesmo problema com filosofias diferentes: Argo CD é um
produto com estado próprio e UI; Flux é um conjunto de controladores compostos.

Escolhido o **Argo CD** por dois motivos. O técnico: o modelo de Application, as
sync waves e os health checks dão controle explícito de ordem de instalação — e
esta stack tem uma cadeia de dependências real (CRDs antes de CRs, webhooks antes
de recursos). O prático: a UI torna drift, self-heal e a árvore de dependências
**visíveis**, sem depender de `kubectl` para inspecionar o estado.

Descartado: Flux (excelente, mas exigiria leitura de logs para ver o mesmo
estado) e Helm puro via CI (é CIOps, não GitOps — sem reconciliação contínua,
sem correção de drift).

---

## 0002 — Vault no cluster + External Secrets Operator

> `docs/adr/0002-vault-eso.md`

**O item de maior risco da entrega, e está marcado como tal no próprio ADR.**

Vault standalone com file storage, autenticação `kubernetes`, e o ESO fazendo a
ponte para Secrets nativos. Zero dependência externa, zero custo, cluster
continua auto-suficiente.

O risco não é o Vault ser difícil — é ele estar no caminho crítico de tudo e
falhar de forma opaca: três causas diferentes (audience errada, caminho `data/`
do kv-v2, cofre selado) produzem a mesma mensagem `permission denied`.

Descartado: 1Password Operator (dependência externa quebra o auto-suficiente),
Sealed Secrets (rotação exige recifrar e commitar), SOPS+age (registrado como
plano B). Ver [Secrets](secrets.md).

---

## 0003 — A fronteira entre Ansible, Terraform e Argo CD

> `docs/adr/0003-fronteira-ansible-terraform-argocd.md`

A decisão central do projeto, resumida numa frase:

> **Ansible faz o que acontece uma vez. Argo CD faz o que precisa acontecer para
> sempre.**

O Terraform provisiona apenas o mínimo imperativo — namespaces, Argo CD, Vault —
e para aí. cert-manager, ESO, CNPG, Reloader e a aplicação vêm pelo GitOps.

O erro que isso evita: colocar os operadores no Terraform cria **disputa de
propriedade**. Dois controladores acreditam ser donos dos mesmos objetos, e o
resultado é `OutOfSync` permanente ou prune de recursos gerenciados pelo
Terraform. Ver [Arquitetura](arquitetura.md).

---

## 0004 — CloudNativePG em vez de StatefulSet ou chart Bitnami

> `docs/adr/0004-cloudnative-pg.md`

Um StatefulSet com a imagem oficial do Postgres dá um banco de pé, não um banco
operado: sem failover, sem replicação, sem backup. Escrever isso à mão é
reimplementar um operador.

CloudNativePG dá failover automático demonstrável em ~10 s, três Services por
papel (`-rw`, `-ro`, `-r`) e rotação de credencial declarativa via
`spec.managed.roles`.

Descartado: os charts Bitnami — a reorganização das imagens em 2025 quebrou
pinagens em produção de muita gente, e um ambiente que se propõe reprodutível não
pode depender disso. Ver [Banco de dados](banco-de-dados.md).

---

## 0005 — A unseal key vive num Secret do próprio cluster

> `docs/adr/0005-unseal-key-no-cluster.md`

**Status: aceito, com ressalva explícita.**

O Vault re-sela a cada restart do pod, e não há KMS de cloud para auto-unseal. A
solução é um Deployment `vault-unsealer` que lê a chave de um Secret e reabre o
cofre em ~10 s.

Isso significa que a chave que protege o Vault está guardada no mesmo cluster que
o Vault protege: **o Vault fica tão seguro quanto o etcd**. O auto-unseal de
cloud faz conceitualmente o mesmo, mas delega a raiz de confiança a um domínio
*diferente*. Aqui não existe outro domínio.

Reconhecer isso explicitamente vale mais do que fingir que é seguro. O ADR
registra o que mudaria numa instalação real: KMS externo, Shamir com múltiplos
detentores, ou Vault gerenciado fora do cluster.

---

## 0006 — Bump de imagem por CI, não pelo Image Updater

> `docs/adr/0006-bump-por-ci.md`

O Argo CD Image Updater automatiza o bump sem CI, mas seu modo padrão de
write-back **muta a Application viva**, e o Git deixa de ser fonte da verdade.

O bump por CI escreve o digest no `values.yaml`, abre PR e faz auto-merge: cada
deploy vira um commit auditável, os checks obrigatórios rodam antes, e o rollback
é `git revert`. Ver [CI/CD](ci-cd.md).

---

## 0007 — Dois repositórios, ambos públicos

> `docs/adr/0007-dois-repositorios.md`

`todolist-app` (código, imagem) e `todolist-platform` (infraestrutura, chart,
GitOps). A separação espelha a fronteira real entre time de produto e time de
plataforma.

Públicos resolve dois problemas de ovo-e-galinha de uma vez: o Argo CD não
precisa de credencial de repositório, e o cluster não precisa de
`imagePullSecret` para o GHCR. Num ambiente privado ambos existiriam, e o ADR
descreve como.

---

## 0008 — TLS com CA interna do cert-manager

> `docs/adr/0008-tls-ca-interna.md`

Let's Encrypt exige domínio público e desafio ACME resolvível. Num cluster em
`*.localhost` isso não existe — **e isso é uma decisão, não uma limitação**.

A cadeia é `selfSigned` → `Certificate` root CA → `ClusterIssuer` do tipo `ca`,
e a partir daí a anotação `cert-manager.io/cluster-issuer` no Ingress emite
certificado por host automaticamente. O mecanismo é idêntico ao de produção; só a
âncora de confiança muda.

Por isso os recursos são `Ingress` padrão e não `IngressRoute` do Traefik: o
ingress-shim do cert-manager só observa `Ingress`. Com `IngressRoute` seria um
`Certificate` manual por host, e o chart deixaria de ser portável para nginx.

`just trust-ca` instala a CA nos stores do sistema e do NSS.

---

## 0009 — gunicorn com 1 worker e 8 threads

> `docs/adr/0009-gunicorn-um-worker.md`

`db.create_all()` roda no import do módulo. Com N workers subindo contra um banco
vazio, N processos criam as mesmas tabelas ao mesmo tempo — `DuplicateTable`
intermitente, o pior tipo de bug.

Um worker elimina a race dentro do pod, e a escala é horizontal via HPA — que é a
resposta nativa do Kubernetes.

A alternativa (`--preload` com `db.engine.dispose()` no `post_fork`) está
documentada: sem o `dispose()`, os filhos herdam sockets do pool do master e
corrompem conexões. É outro bug intermitente, trocado por um bug intermitente.

---

## Decisões menores, registradas nos comentários do código

Nem tudo merece ADR, mas nada deveria ser inexplicável. Estas estão comentadas no
ponto onde importam:

| Decisão | Onde |
|---|---|
| `*.localhost` em vez de `nip.io` | `roles/preflight`, [Arquitetura](arquitetura.md) |
| Liveness em `/login`, não em `/healthz` | `templates/deployment.yaml`, [Escalabilidade](escalabilidade.md) |
| `ttlSecondsAfterFinished` omitido | `templates/cronjob-cleanup.yaml` |
| Sem limit de CPU | `values.yaml` |
| `ScheduleAnyway` no topology spread | `templates/deployment.yaml` |
| `wait = false` no `helm_release` do Vault | `terraform/vault.tf`, [Bootstrap](bootstrap.md) |
| Reloader com anotação explícita, não `auto: true` | `gitops/apps/`, [Secrets](secrets.md) |
| `alekc/kubectl` em vez de `gavinbunney/kubectl` | `terraform/versions.tf` |
