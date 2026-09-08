# Arquitetura

## Visão geral

```
                            máquina Linux (host)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  :80 :443                                                            │
 │     │                                                                │
 │     ▼                                                                │
 │  k3d-serverlb ──► cluster k3d: 1 server + 3 agents (contêineres)      │
 │                     │                                                │
 │   ┌─────────────────┴──────────────────────────────────────────────┐ │
 │   │  namespace argocd     Argo CD ─── observa ──► GitHub           │ │
 │   │  namespace vault      Vault + vault-unsealer                   │ │
 │   │  namespace cert-manager                                        │ │
 │   │  namespace external-secrets   ESO                              │ │
 │   │  namespace cnpg-system        operator do CloudNativePG        │ │
 │   │  namespace todolist   app (HPA 2–6) + Postgres (3) + CronJob   │ │
 │   │  namespace kube-system  Traefik, metrics-server, CoreDNS       │ │
 │   └────────────────────────────────────────────────────────────────┘ │
 └──────────────────────────────────────────────────────────────────────┘
```

## As camadas e a fronteira entre elas

Esta é a decisão central do projeto, e vale mais que qualquer escolha de
ferramenta individual.

```
setup.sh    → dependências locais, versões fixadas, sysctl de inotify
Terraform   → APENAS namespaces + Argo CD + Vault
Ansible     → orquestra o Day-0: k3d → terraform → unseal → seed → root App
Argo CD     → TODO o resto: cert-manager, ESO, CNPG, Reloader, a aplicação
Helm        → empacotamento da aplicação
Justfile    → fachada de uso
```

**Só existe uma coisa instalada imperativamente, e é a coisa que torna todo o
resto declarativo: o Argo CD.** E uma segunda, o Vault, porque a cerimônia de
seal/unseal é irredutivelmente procedural.

A regra que separa Ansible de Argo CD:

> **Ansible faz o que acontece uma vez. Argo CD faz o que precisa acontecer para
> sempre.**

E a que define o papel do Terraform:

> **O Terraform provisiona o mínimo imperativo — o que precisa existir antes de o
> GitOps poder existir.**

### Por que cert-manager, ESO e CNPG não estão no Terraform

Seria tecnicamente possível — e criaria disputa de propriedade. Dois
reconciliadores gerenciando o mesmo recurso produzem `OutOfSync` permanente, ou
pior: o Argo CD com `prune` habilitado apagando recursos que o Terraform criou,
e o `terraform apply` seguinte recriando. Um objeto tem um dono.

Mantê-los no GitOps também é o que torna a operação coerente: depois do
bootstrap, **toda mudança de plataforma é um commit**.

### Por que o Vault não é uma Application do Argo CD

O readiness probe do chart do Vault é `vault status`, que retorna exit 2 enquanto
o cofre está selado. O pod **nunca fica Ready antes do unseal**.

Como Application, o StatefulSet ficaria 0/1, a Application ficaria `Progressing`
para sempre, e a sync wave nunca avançaria — esperando um unseal que ninguém pode
fazer, porque o processo de bootstrap está esperando o sync. Circular.

Pelo mesmo motivo, o `helm_release` do Vault no Terraform usa **`wait = false`**.

## Fluxo de uma requisição

```
browser  ──https──►  k3d-serverlb :443
                          │
                          ▼
                     Traefik (websecure)
                     certificado emitido pelo cert-manager
                          │
                          ▼
                     Service todolist (ClusterIP)
                          │
                          ▼
                     pod todolist (gunicorn, 1 worker / 8 threads)
                          │
                          ▼
                     Service todolist-pg-rw ──► primário do Postgres
```

O Service `-rw` do CloudNativePG aponta sempre para o primário atual. A aplicação
não sabe, e não precisa saber, qual instância é a primária depois de um failover.

## Fluxo de um segredo

```
ansible/group_vars/all/vault.yml    (cifrado com ansible-vault, versionado)
        │  bootstrap, uma vez
        ▼
   Vault kv-v2  secret/todolist/{app,db}      ← fonte da verdade em runtime
        │  ClusterSecretStore + auth/kubernetes
        ▼
   External Secrets Operator
        ├──► Secret todolist-app   (Opaque)              → arquivos no pod
        └──► Secret todolist-db    (basic-auth)          → CloudNativePG
        │
        ▼
   /var/run/secrets/todolist/{SESSION_KEY,DB_PASSWORD,...}
```

Nenhum objeto `kind: Secret` existe no repositório, em nenhuma forma. Detalhes em
[Secrets](secrets.md).

## Fluxo de uma atualização de imagem

```
push em todolist-app
   → CI: lint, scan, testes, build multi-arch, push no GHCR, assinatura
   → repository_dispatch
        → todolist-platform: bump do DIGEST no values.yaml, PR com auto-merge
             → Argo CD detecta o commit
                  → rolling update
```

Detalhes em [CI/CD](ci-cd.md).

## Escolhas de infraestrutura

**k3d com 4 nós, e não 1.** Torna `topologySpreadConstraints` e `kubectl drain`
demonstráveis. A imagem do k3s é fixada por versão (`rancher/k3s:v1.31.4-k3s1`),
porque reprodutibilidade é o requisito de provisionamento automatizado e uma tag
flutuante o quebraria em silêncio.

**Traefik embutido, não instalado.** O k3s já traz um Traefik gerenciado pelo
`helm-controller`. Instalar um segundo faria os dois disputarem os mesmos
`Ingress`.

**Hostnames em `*.localhost`.** O `systemd-resolved` resolve qualquer
`algo.localhost` para 127.0.0.1 nativamente, sem DNS externo. As alternativas
(`nip.io`, `sslip.io`) falham em redes com proteção contra DNS rebinding — o que
inclui a maioria dos resolvers corporativos, dnsmasq e pi-hole.

**`Ingress` padrão, não `IngressRoute`.** O ingress-shim do cert-manager só
observa `Ingress`; com `IngressRoute` seria preciso declarar cada `Certificate` na
mão. `Ingress` também é portável para nginx ou kind sem reescrita.

## Requisitos do ambiente hospedeiro

Verificados automaticamente pelo papel `preflight`, que falha com mensagem
explícita:

| Item | Valor mínimo | Por quê |
|---|---|---|
| Docker | rodando, acessível pelo usuário | os nós são contêineres |
| Portas 80 e 443 | livres | publicadas pelo `serverlb` |
| Memória livre | ~6 GB | Argo CD + Vault + 3 Postgres + operators |
| `fs.inotify.max_user_instances` | ≥ 512 | ver abaixo |
| `fs.inotify.max_user_watches` | ≥ 524288 | idem |

O default do Ubuntu para `max_user_instances` é **128**. Quatro nós mais Argo CD,
Vault, ESO e CNPG estouram esse limite de forma confiável, e o sintoma é opaco:
`too many open files` e o k3s reiniciando sem causa aparente. É a causa mais
comum de "funciona na minha máquina" com k3d, e por isso é verificada antes de
qualquer outra coisa.
