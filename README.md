# todolist-platform

Ambiente completo da aplicação [todolist-app](https://github.com/frankjuniorr/todolist-app)
em Kubernetes, provisionado por código e operado por GitOps. Uma máquina Linux
limpa sobe tudo com **um comando**.

```bash
./scripts/setup.sh              # dependências locais, em versões fixadas
just configure SEU_USUARIO      # grava a URL do repositório (uma vez, depois commite)
just up                         # sobe tudo
```

Ao final: `https://todolist.localhost`, com usuário e senha exibidos por
`just urls`.

---

## O que é

Um cluster Kubernetes local (k3d) com a aplicação `todolist-app` rodando de
ponta a ponta: banco de dados com failover automático, segredos vindos de um
cofre (não do Git), TLS automático, autoscaling sob carga, e atualização
automática sempre que uma imagem nova é publicada — tudo declarado como código e
reconciliado continuamente pelo Argo CD.

```
   just up
      │
      ├── preflight ......... o host aguenta? (docker, portas, inotify, memória)
      ├── k3d ............... cluster: 1 server + 3 agents, 80/443 publicados
      ├── terraform ......... namespaces + Argo CD + Vault      ← única camada imperativa
      ├── vault ............. init, unseal, auth/kubernetes, unsealer
      ├── seed .............. valores-semente no kv-v2
      └── argo cd ........... App-of-Apps  ← daqui em diante, tudo é GitOps
                                 │
                                 ├── cert-manager  → CA interna e TLS
                                 ├── external-secrets → Vault ⇒ Secrets do k8s
                                 ├── cloudnative-pg → Postgres com failover
                                 ├── reloader → rollout na rotação de secret
                                 └── charts/todolist → a aplicação
```

## Como usar, no dia a dia

```bash
just status            # o cluster está saudável?
just urls              # endereços e credenciais
just logs              # logs da aplicação em tempo real
just psql              # psql interativo no primário do Postgres
just demo-scale        # gera carga até o HPA escalar
just demo-chaos        # mata pods, drena um nó, derruba o primário, sela o Vault
just down && just up   # derruba e reconstrói do zero
```

Depois do bootstrap, **nenhuma mudança de plataforma ou de aplicação é feita à
mão no cluster** — tudo passa por um commit em `gitops/` ou `charts/todolist/`,
e o Argo CD sincroniza sozinho.

## Onde cada ferramenta para

| Camada | Responsabilidade | Por quê |
|---|---|---|
| `scripts/setup.sh` | dependências da máquina | Day -1 |
| `ansible/` | o que acontece **uma vez** | bootstrap, seal/unseal, semente |
| `terraform/` | **só** namespaces, Argo CD, Vault | o mínimo para o GitOps existir |
| `gitops/` + Argo CD | o que precisa acontecer **para sempre** | reconciliação contínua |
| `charts/todolist/` | empacotamento da aplicação | um chart, vários ambientes |
| `Justfile` | fachada de UX | o comando que alguém digita sob pressão |

## Secrets

**Nenhum manifesto de Secret do Kubernetes existe neste repositório**, nem
cifrado. O que é versionado são os *valores-semente*, cifrados com
`ansible-vault`; o Secret real é materializado dentro do cluster pelo External
Secrets Operator a partir de um Vault que roda no próprio cluster. Detalhes
completos em [`docs/secrets.md`](docs/secrets.md).

## Comandos

```
just up            # sobe tudo
just down          # destrói o cluster e o tfstate
just status        # estado + checagem dos invariantes
just urls          # URLs e credenciais
just logs          # logs da aplicação
just psql          # psql interativo no primário do Postgres
just secrets-init  # cria o vault.yml cifrado
just secrets-edit  # edita os valores-semente
just secrets-rotate SESSION_KEY
just demo-scale    # carga até o HPA escalar
just demo-chaos    # mata pods, drena node, failover do Postgres, sela o Vault
just lint          # helm, kubeconform, terraform, ansible, shellcheck
just e2e           # prova ponta a ponta
```

## Documentação

- [`docs/`](docs/) — cada etapa e cada ferramenta explicada em detalhe:
  arquitetura, bootstrap, GitOps, secrets, banco de dados, escalabilidade,
  CI/CD e o índice de decisões
- [`docs/adr/`](docs/adr/) — uma decisão de arquitetura por arquivo, com as
  alternativas descartadas e o porquê
