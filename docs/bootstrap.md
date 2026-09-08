# Bootstrap — o que acontece durante `just up`

Um comando, seis fases, cerca de 5 a 8 minutos. Cada fase existe porque a
seguinte depende dela, e a ordem foi escolhida para eliminar dependências
circulares — não por conveniência.

```bash
just up      # ansible-playbook ansible/site.yml
```

---

## Fase 0 — `just setup` (uma vez por máquina)

Instala as dependências locais **com versões fixadas**: k3d, kubectl, helm,
terraform, just, argocd CLI, kubeconform, hey. Versão flutuante quebra
reprodutibilidade em silêncio.

Aplica também os `sysctl` de inotify em `/etc/sysctl.d/99-k3d.conf`, de forma
persistente. Ver [Arquitetura](arquitetura.md#requisitos-do-ambiente-hospedeiro).

---

## Fase 1 — `preflight`

Verifica antes de criar qualquer coisa:

- Docker rodando e acessível pelo usuário;
- os binários necessários no `PATH`;
- portas 80 e 443 livres;
- memória livre suficiente;
- `fs.inotify.max_user_instances` ≥ 512 e `max_user_watches` ≥ 524288;
- **nenhum placeholder pendente** no repositório (ver abaixo).

Falhar aqui é barato e a mensagem aponta para a causa. Falhar no meio da criação
do cluster é caro, e o sintoma raramente aponta para a causa.

### O assert de placeholder

O repositório é publicado com `PLACEHOLDER_REPO_URL` e `CHANGEME` no lugar da URL
do repositório e do usuário do GHCR. Isso **não** pode ser resolvido em tempo de
execução: o Argo CD lê os manifestos das Applications filhas diretamente do Git,
então um `sed` local nunca chegaria até ele.

A resolução é um passo explícito, feito uma vez e **commitado**:

```bash
just configure seu-usuario
```

O `preflight` falha enquanto restar qualquer placeholder, com a instrução exata.
Sem esse assert, o sintoma seria uma Application em erro de repositório vinte
minutos depois.

---

## Fase 2 — `k3d_cluster`

```bash
k3d cluster create todolist \
  --image=rancher/k3s:v1.31.4-k3s1 \
  --servers=1 --agents=3 \
  --port=80:80@loadbalancer --port=443:443@loadbalancer \
  --wait --timeout=300s
```

Idempotente: verifica `k3d cluster list -o json` antes de criar.

Publicar 80 e 443 no `serverlb` é o que torna `https://todolist.localhost`
acessível do navegador do host **sem port-forward**.

O Traefik embutido **não** é desabilitado. Instalar um segundo ingress controller
faria os dois disputarem os mesmos objetos `Ingress`, com o `helm-controller` do
k3s reinstalando o original.

Depois de os nós ficarem Ready, as imagens críticas são pré-carregadas com
`k3d image import`. Isso evita o rate limit anônimo do Docker Hub (100 pulls por
6 horas), que quatro nós puxando imagens simultaneamente atingem com facilidade.

---

## Fase 3 — `platform` (Terraform)

```
terraform/
├── namespaces.tf   namespaces com labels de Pod Security Admission
├── argocd.tf       helm_release do Argo CD
├── vault.tf        helm_release do Vault  (wait = false)
├── versions.tf     providers fixados
└── outputs.tf
```

Providers: `hashicorp/kubernetes`, `hashicorp/helm` e `alekc/kubectl`.

Duas escolhas deliberadas:

- **`gavinbunney/kubectl` está abandonado** e quebra com Terraform 1.6+; o fork
  `alekc/kubectl` é o mantido.
- **`kubernetes_manifest` não é usado.** Ele consulta o schema do recurso em
  *plan time*; para qualquer CR cujo CRD ainda não exista, o plan falha. É
  incompatível com bootstrap.

O `helm_release` do Vault usa **`wait = false`**. Com `wait = true`, o Terraform
esperaria o pod ficar Ready, o que só acontece depois do unseal — que só acontece
na fase seguinte, depois do Terraform terminar. Deadlock literal, resolvido por
timeout de 10 minutos e falha.

O Argo CD é configurado com `configs.params."server.insecure": true`. Sem isso, o
Traefik termina o TLS e o Argo CD redireciona para HTTPS de novo:
`ERR_TOO_MANY_REDIRECTS`.

Ao final, o playbook escreve `.argocd-admin` (modo 0600, gitignored) com a senha
inicial.

---

## Fase 4 — `vault_bootstrap`

A fase mais delicada, e a única irredutivelmente imperativa: **nenhuma ferramenta
declarativa destranca um cofre**.

```
1. esperar phase=Running        (NÃO condition=Ready — ver abaixo)
2. vault status                 (failed_when: false — exit 2 é esperado)
3. vault operator init -key-shares=1 -key-threshold=1
4. persistir .vault-keys.json   (0600, gitignored)
5. vault operator unseal
6. criar o Secret vault-unseal e aplicar o Deployment vault-unsealer
7. vault secrets enable -path=secret kv-v2
8. vault auth enable kubernetes  +  auth/kubernetes/config
9. vault policy write todolist   (caminho secret/data/... — não secret/...)
10. vault write auth/kubernetes/role/todolist \
       bound_service_account_names=external-secrets-vault \
       audience=""
```

Quatro detalhes que valem registro:

**`phase=Running`, não `condition=Ready`.** O readiness probe do chart é
`vault status`, que retorna exit 2 enquanto selado. Esperar por Ready antes do
unseal é esperar para sempre.

**`failed_when: false` no `vault status`.** Exit 2 significa "selado", não erro. O
Ansible interpretaria como falha e abortaria.

**O caminho `data/` na policy.** O engine kv-v2 armazena sob
`secret/data/todolist/app`, enquanto o CLI aceita `secret/todolist/app` e corrige
sozinho. Uma policy escrita com `secret/todolist/*` funciona pelo CLI e falha pelo
ESO — com a mensagem genérica `permission denied`.

**O unsealer aponta para o Service headless.** Um Service comum remove pods não
prontos dos seus endpoints, e o Vault nunca está pronto enquanto selado — o
unsealer não alcançaria justamente o Vault que existe para destrancar. O endereço
correto é `vault-0.vault-internal.vault.svc.cluster.local:8200`, porque o Service
headless usa `publishNotReadyAddresses: true`.

O unsealer é um **Deployment** em loop, não um CronJob: a granularidade mínima de
um CronJob é um minuto, e a recuperação desejada é de segundos.

---

## Fase 5 — `seed_secrets`

Escreve os valores no Vault:

```
secret/todolist/app  →  SESSION_KEY, ADMIN_USER, ADMIN_PASSWORD, CLEANUP_TOKEN
secret/todolist/db   →  username, password
```

A origem dos valores é `ansible/group_vars/all/vault.yml`, cifrado com
ansible-vault e versionado. **Quando esse arquivo não pode ser decifrado, o
playbook gera valores aleatórios de 32 caracteres.**

Isso é deliberado e preserva a promessa de "um comando": se o playbook exigisse
`--ask-vault-pass`, quem clona o repositório pararia num prompt de senha que não
tem; se a senha fosse commitada, a cifragem seria teatro. Com valores geráveis, o
ambiente sobe igual numa máquina limpa — apenas com credenciais diferentes.

Como nesse caso ninguém conhece as credenciais geradas, o playbook escreve
`.app-credentials` (0600, gitignored), exibido por `just urls`.

Todas as tarefas que tocam valores usam `no_log: true`.

---

## Fase 6 — `gitops_bootstrap`

```bash
kubectl apply -f gitops/root-app.yaml
```

Uma única `Application`, que aponta para `gitops/apps/` — o padrão App-of-Apps. A
partir daqui o Argo CD assume, e nada mais é aplicado imperativamente.

**Esta fase é a última de propósito.** Quando o Argo CD começa a reconciliar, o
Vault já responde e já tem os valores — então o `ExternalSecret` da wave -3
encontra um cofre aberto em vez de um 503. É assim que o chicken-and-egg é
evitado: não com retry, mas com ordem.

O papel então espera (120 tentativas, 10 s) até que todas as Applications estejam
`Healthy` e `Synced`, e verifica um invariante da aplicação: **exatamente um
CronJob no namespace** (ver [Escalabilidade](escalabilidade.md#o-cronjob-de-limpeza)).

---

## Verificando

```bash
just status     # nós, pods, Applications, HPA, e o invariante do CronJob
just urls       # endereços e credenciais
just e2e        # down + up + asserções ponta a ponta
```

O `just down` apaga o cluster **e o `terraform.tfstate`**. Sem isso, um segundo
`just up` tentaria fazer refresh do estado contra um API server que não existe
mais.
