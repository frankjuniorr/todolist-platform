# Secrets

## O princípio

**Nenhum objeto `kind: Secret` existe no repositório, em nenhuma forma — nem em
claro, nem cifrado.**

O que é versionado é uma lista de valores-semente cifrada com ansible-vault. Esses
valores são escritos no Vault uma única vez, no bootstrap, e a partir daí **o
Vault é a fonte da verdade**.

```
ansible/group_vars/all/vault.yml       cifrado (ansible-vault), versionado
        │
        │  bootstrap, uma vez
        ▼
   Vault kv-v2  secret/todolist/{app,db}
        │
        │  ClusterSecretStore + auth/kubernetes
        ▼
   External Secrets Operator
        ├──► Secret todolist-app  (Opaque)             → arquivos no pod da app
        └──► Secret todolist-db   (basic-auth)         → CloudNativePG
        │
        ▼
   /var/run/secrets/todolist/SESSION_KEY, DB_PASSWORD, ...
```

## Por que não cifrar o manifesto de Secret e commitar

Funcionaria — Sealed Secrets e SOPS existem para isso, e são escolhas legítimas.
O que essa abordagem resolve é confidencialidade; o que ela não resolve é ciclo
de vida:

- **Rotação vira commit.** Toda troca de senha é uma mudança no repositório.
- **O valor antigo fica no histórico para sempre.** Um `git commit` feito antes de
  cifrar — que acontece — não é reversível sem reescrever histórico.
- **Não há audit log de leitura.** Quem leu o segredo, e quando, é uma pergunta
  sem resposta.

Com um secret manager, rotação é uma chamada de API e nada toca o Git.

O custo é uma peça a mais para operar, e ele é real. O plano B declarado era
SOPS + age com KSOPS ([ADR 0002](adr/0002-vault-eso.md)).

## O arquivo cifrado

```yaml
# ansible/group_vars/all/vault.yml.example
seed_secrets:
  SESSION_KEY: "..."
  ADMIN_USER: "admin"
  ADMIN_PASSWORD: "..."
  CLEANUP_TOKEN: "..."
  DB_USER: "todolist"
  DB_PASSWORD: "..."
```

```bash
just secrets-init      # gera .vault-pass, copia o exemplo e cifra
just secrets-edit      # decifra em memória, recifra ao salvar
```

`vault.yml` **é** versionado. `.vault-pass` **não** é — e há um comentário
explícito no `.gitignore` dizendo isso, porque a leitura natural seria supor
esquecimento.

### Valores-semente são opcionais, de propósito

O objetivo é que uma máquina qualquer suba tudo com um comando. Mas quem clona
o repositório não tem a senha do ansible-vault. As duas saídas óbvias são ruins:
`--ask-vault-pass` para num prompt e mata a promessa de "um comando"; commitar a
senha torna a cifragem teatro.

A solução implementada: **quando o arquivo cifrado não pode ser decifrado, o
playbook gera valores aleatórios de 32 caracteres.** O ambiente sobe igual, com
credenciais diferentes.

Como nesse caso ninguém conhece as credenciais geradas, o playbook escreve
`.app-credentials` (modo 0600, gitignored), exibido por `just urls`.

## Vault

Standalone, storage em arquivo sobre PVC, engine kv-v2 no mount `secret`.

### Seal e unseal

O Vault guarda os dados cifrados por uma chave que ele não mantém em disco. Ao
iniciar, está **selado**: responde na rede e recusa todas as operações. Alguém
precisa fornecer a unseal key.

Não há KMS de nuvem disponível aqui, então não há auto-unseal. A solução é um
Deployment `vault-unsealer` que observa o estado e reabre o cofre em ~10 segundos.

Dois detalhes que fazem a diferença entre funcionar e não funcionar:

**O unsealer aponta para `vault-0.vault-internal`, não para o Service `vault`.**
Um Service comum remove pods não prontos dos seus endpoints, e o Vault nunca fica
pronto enquanto selado — o unsealer não alcançaria justamente o Vault que existe
para destrancar. O Service headless usa `publishNotReadyAddresses: true`.

**É um Deployment em loop, não um CronJob.** A granularidade mínima de um CronJob
é um minuto; a recuperação desejada é de segundos.

### O trade-off, declarado

A unseal key vive num Secret do mesmo cluster que o Vault protege. **O Vault fica
tão seguro quanto o etcd.**

O auto-unseal de nuvem faz conceitualmente a mesma coisa — delega a reconstrução
da chave a outro sistema. A diferença é que lá esse sistema é um **domínio de
confiança diferente**, com IAM próprio. Aqui não existe outro domínio.

Isso está registrado como decisão consciente no [ADR 0005](adr/0005-unseal-key-no-cluster.md),
com a alternativa correta (KMS ou Transit unseal contra outro Vault) nomeada. Num
ambiente real, seria essa.

## External Secrets Operator

O ESO lê do Vault e materializa `Secret` nativos do Kubernetes. A aplicação
continua vendo apenas Kubernetes puro — se o cofre mudasse para AWS Secrets
Manager, mudaria um objeto de plataforma e nada no chart.

**`ClusterSecretStore`** — onde é o cofre e como autenticar:

```yaml
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "todolist"
          serviceAccountRef: { name: external-secrets-vault, namespace: todolist }
```

**`ExternalSecret`** — o que buscar e onde escrever:

```yaml
spec:
  refreshInterval: 1m
  target: { name: todolist-app, creationPolicy: Owner }
  data:
    - secretKey: SESSION_KEY
      remoteRef: { key: secret/todolist/app, property: SESSION_KEY }
    - secretKey: DB_USER
      remoteRef: { key: secret/todolist/db, property: username }
    ...
```

`creationPolicy: Owner` cria uma `ownerReference`: apagar o `ExternalSecret`
apaga o Secret junto.

### Autenticação sem credencial estática

```
ESO pede um token de ServiceAccount ao API server   (TokenRequest API)
   → apresenta o JWT ao Vault  (auth/kubernetes/login)
      → Vault pergunta ao API server se o token é válido  (TokenReview)
         → Vault confere a role: essa SA, nesse namespace, está autorizada?
            → devolve um token do Vault com a policy amarrada
```

Nenhuma senha do Vault existe em lugar nenhum. A identidade é a própria
ServiceAccount, e o Vault delega a verificação ao Kubernetes — mesma ideia de
IRSA na AWS ou Workload Identity no GCP.

### Dois pontos onde isso falha com a mesma mensagem

`permission denied` é a resposta do Vault para várias causas diferentes. As duas
mais prováveis:

**Mismatch de audience.** O token cunhado pela TokenRequest API carrega uma
*audience*; a role do Vault declara qual aceita. Se divergirem, `permission
denied`.

**Caminho sem `data/` na policy.** O kv-v2 armazena em
`secret/data/todolist/app`, embora o CLI aceite `secret/todolist/app` e corrija
sozinho. Uma policy escrita como `secret/todolist/*` **funciona pelo CLI e falha
pelo ESO**.

Ambas produzem exatamente a mesma mensagem que uma policy genuinamente errada.

### O `template` precisa ser determinístico

Se o bloco `template` do `ExternalSecret` renderizasse conteúdo variável — um
timestamp, por exemplo — o Secret seria reescrito a cada `refreshInterval`, o
Reloader detectaria a mudança, e a aplicação reiniciaria **a cada minuto, para
sempre**. O sintoma seriam pods reiniciando sem motivo aparente.

## Do Secret ao arquivo dentro do pod

A aplicação lê secrets de arquivo, e só cai na variável de ambiente se o arquivo
não existir. Isso é do código dela, não uma escolha de plataforma:

```python
def _config(name, default=""):
    try:
        with open(os.path.join(SECRETS_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name, default)
```

Um arquivo por secret, com o nome exato da variável:

```
/var/run/secrets/todolist/
├── SESSION_KEY
├── ADMIN_USER
├── ADMIN_PASSWORD
├── CLEANUP_TOKEN
├── DB_USER
└── DB_PASSWORD
```

Declarado no chart:

```yaml
volumes:
  - name: secrets
    secret:
      secretName: todolist-app
      defaultMode: 0440
      items:
        - { key: SESSION_KEY, path: SESSION_KEY }
        ...
```

### Três detalhes que causam bug silencioso

**`defaultMode: 0440` com `fsGroup` correto.** O `except OSError` do código
captura `PermissionError` **sem logar nada** e devolve o fallback — string vazia.
`DB_PASSWORD` vira `''` e o erro que aparece é
`password authentication failed for user "todolist"`. A senha está certa; o
arquivo é que não foi lido. `fsGroup: 10001` faz o kubelet ajustar o grupo dono
do volume.

**Nunca `subPath`.** Montagens com `subPath` **não são atualizadas pelo kubelet**
quando o Secret muda. A rotação para de funcionar e nada indica isso. O job
`invariantes` do CI faz `grep` por `subPath` nos templates e falha se encontrar.

**`items` explícito.** Sem ele o Kubernetes criaria um arquivo por chave
automaticamente. Está explícito porque funciona como contrato — uma chave nova no
Vault não chega ao pod sem passar por aqui. É o que garante que o pod do CronJob
monte apenas `CLEANUP_TOKEN`, e nunca veja `DB_PASSWORD`.

## Rotação

```bash
just secrets-rotate SESSION_KEY
```

O que acontece:

```
vault kv patch secret/todolist/app SESSION_KEY=<novo>
   → ESO reescreve o Secret         (até 1 min, refreshInterval)
      → Reloader detecta e reinicia o Deployment
         → o arquivo no pod novo tem o valor novo
```

**Por que o Reloader e não `checksum/config`.** O truque clássico do Helm —
anotar o Deployment com o hash do Secret — não funciona aqui, porque o Helm não
conhece o conteúdo: quem cria o Secret é o ESO. O Reloader é um controller que
observa o Secret de verdade.

Ele usa anotação explícita (`secret.reloader.stakater.com/reload`), não
`auto: true`, e roda com `watchGlobally: false`. Reinício de workload é ação
destrutiva; ela deve ser declarada, não inferida.

**Um contraste que vale entender:**

| Consumidor | Quando lê | Precisa de restart? |
|---|---|---|
| aplicação Flask | uma vez, no import do módulo | **sim** — daí o Reloader |
| pod do CronJob | a cada execução | **não** — o pod é novo toda vez |

**Não rotacione `DB_PASSWORD` sem `spec.managed.roles`.** O `bootstrap.initdb` do
CNPG roda uma única vez; trocar o Secret depois deixaria a senha nova no Secret e
a antiga no banco. Ver [Banco de dados](banco-de-dados.md).

## Verificando

```bash
git log -p | grep -i password        # não deve retornar valor nenhum
kubectl -n todolist get externalsecret
kubectl -n todolist describe externalsecret todolist-app
kubectl -n todolist exec deploy/todolist -- ls -l /var/run/secrets/todolist
kubectl -n vault exec vault-0 -- vault status
```
