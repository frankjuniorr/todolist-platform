# todolist-platform

Ambiente completo da aplicação [todolist-app](https://github.com/frankjuniorr/todolist-app)
em Kubernetes, do zero, com **um comando**.

```bash
./scripts/setup.sh              # dependências locais, em versões fixadas
just configure SEU_USUARIO      # grava a URL do repositório (uma vez, depois commite)
just up                         # sobe tudo
```

Ao final: `https://todolist.localhost`.

---

## O que sobe

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

## A decisão central: onde cada ferramenta para

Existe **uma** coisa instalada imperativamente, e é justamente a coisa que torna
todo o resto declarativo: o **Argo CD**. E uma segunda, o **Vault**, porque
destrancar um cofre é irredutivelmente imperativo.

| Camada | Responsabilidade | Por quê |
|---|---|---|
| `scripts/setup.sh` | dependências da máquina | Day -1 |
| `ansible/` | o que acontece **uma vez** | bootstrap, seal/unseal, semente |
| `terraform/` | **só** namespaces, Argo CD, Vault | o mínimo para o GitOps existir |
| `gitops/` + Argo CD | o que precisa acontecer **para sempre** | reconciliação contínua |
| `charts/todolist/` | empacotamento da aplicação | um chart, vários ambientes |
| `Justfile` | fachada de UX | o comando que alguém digita sob pressão |

Colocar cert-manager, ESO ou CNPG no Terraform criaria disputa de propriedade
com o Argo CD — `OutOfSync` permanente, ou o Terraform removendo o que o Argo CD
acabou de criar. Cada recurso tem exatamente um dono.

## Segurança dos secrets

**Nenhum manifesto de Secret do Kubernetes existe neste repositório**, nem
cifrado. O que é versionado são os *valores-semente*, cifrados com
`ansible-vault`; o Secret é materializado dentro do cluster pelo External
Secrets Operator a partir do Vault.

```
ansible/group_vars/all/vault.yml   (cifrado, commitado)
        │  escrito uma vez, no bootstrap
        ▼
   Vault kv-v2  ← fonte da verdade em runtime
        │  ClusterSecretStore + auth/kubernetes
        ▼
External Secrets Operator
        ├─→ Secret todolist-app  (Opaque)              → arquivos em SECRETS_DIR
        └─→ Secret todolist-db   (basic-auth)          → CloudNativePG
        │
        ▼  Reloader observa o Secret → rolling restart na rotação
```

Isso elimina uma classe inteira de vazamento: um Secret cifrado no Git continua
recuperável em qualquer commit anterior se a chave vazar depois. Aqui ele nunca
esteve lá.

Se `vault.yml` não existir, o playbook **gera** valores aleatórios de 32
caracteres. É o que mantém a promessa de "um comando" numa máquina que nunca viu
a senha do vault — sem isso, o playbook pararia num prompt.

## Mapa requisito → implementação

| Requisito | Onde |
|---|---|
| R1 — provisionamento automatizado por código | `ansible/site.yml`, `terraform/`, versões fixadas em `scripts/setup.sh` |
| R2 — deployment automatizado | Argo CD com auto-sync + `self-heal`; `image-bump.yml` fecha o ciclo desde o push na aplicação |
| R3 — acesso externo pelo navegador | k3d publica 80/443, Traefik embutido, `Ingress` + cert-manager |
| R4 — escalabilidade e resiliência | HPA 2–6, PDB, topology spread, 3 probes distintas, CNPG com 3 instâncias |
| R5 — documentação e decisões | este README, `docs/adr/`, `docs/runbook.md`, a Wiki |

## Comandos

```
just up            # sobe tudo
just down          # destrói o cluster e o tfstate
just status        # estado + checagem dos invariantes
just urls          # URLs e credenciais
just logs          # logs da aplicação
just secrets-init  # cria o vault.yml cifrado
just secrets-edit  # edita os valores-semente
just secrets-rotate SESSION_KEY
just demo-scale    # carga até o HPA escalar
just demo-chaos    # mata pods, drena node, failover do Postgres, sela o Vault
just lint          # helm, kubeconform, terraform, ansible, shellcheck
just e2e           # prova ponta a ponta
```

## Invariantes que a aplicação impõe

Levantados lendo `app.py`, não a documentação. Quebrar qualquer um deles falha
**em silêncio** — daí existirem checagens automatizadas para eles:

- **Exatamente 1 CronJob** no namespace. `app.py` devolve `None` se a contagem
  diferir, e duas telas param de funcionar sem erro visível.
- **Secrets como arquivos**, com `defaultMode: 0440` e `fsGroup` batendo com o
  GID da imagem. Sem permissão de leitura, `_config()` captura o `OSError` e
  devolve string vazia — o sintoma vira "senha inválida".
- **Nunca `subPath`** ao montar Secret: montagens com `subPath` não recebem
  atualização do kubelet, e a rotação para de funcionar silenciosamente.
- **Sem `ttlSecondsAfterFinished`** no CronJob: o TTL controller apaga os pods,
  e é dos pods que a tela de histórico é construída.
- **`automountServiceAccountToken: true`**: as telas `/pods` e `/cleanup/status`
  falam com a API do Kubernetes.

## Documentação

- `docs/adr/` — uma decisão por arquivo, com as alternativas descartadas
- `docs/runbook.md` — o que fazer quando algo quebra
- `docs/desafios-encontrados.md` — as armadilhas reais, anotadas quando doeram
- Wiki do repositório — versão navegável, com capturas de tela

## Dois bugs encontrados na aplicação

Não corrigidos (o escopo aqui é a plataforma, não a aplicação), mas registrados:

1. `history.sort()` ordena a string já formatada `'%d/%b %H:%M'` — a ordem
   quebra na virada de mês.
2. Não há `pool_pre_ping` no SQLAlchemy — após um failover do Postgres, as
   conexões em pool ficam stale por ~30 s antes de o pool se recuperar.
