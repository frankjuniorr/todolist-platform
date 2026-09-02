# Runbook

O que fazer quando algo quebra. Escrito para ser lido às pressas.

## Diagnóstico em 30 segundos

```bash
just status
kubectl -n argocd get applications.argoproj.io
kubectl -n todolist get pods
kubectl -n todolist get events --sort-by=.lastTimestamp | tail -20
```

---

## A aplicação não sobe

### `Init:0/1` — parado no initContainer

O banco não está aceitando conexão autenticada. **Isto é bom**: significa que o
initContainer fez o trabalho dele — sem ele, o sintoma seria `CrashLoopBackOff`
e você procuraria o erro na aplicação.

```bash
kubectl -n todolist logs <pod> -c wait-for-db
kubectl -n todolist get cluster.postgresql.cnpg.io
kubectl -n todolist get secret todolist-db -o jsonpath='{.data.username}' | base64 -d
```

Cause mais comum: `postgres.owner` no `values.yaml` diferente do campo
`username` do Secret. O `initdb` cria o role de `owner`, e a aplicação tenta
logar com outro nome.

### `CrashLoopBackOff` com "password authentication failed"

Pode não ser a senha. `_config()` captura `OSError` e **cai no fallback em
silêncio** — se o arquivo do secret existir mas não for legível pelo processo,
`DB_PASSWORD` vira string vazia e o Postgres responde exatamente isso.

```bash
kubectl -n todolist exec <pod> -- ls -l /var/run/secrets/todolist
```

Os arquivos devem ser `-r--r-----` e o grupo deve ser `10001` (o `fsGroup`).

### `CreateContainerConfigError`

O Secret `todolist-app` não existe. O ESO não conseguiu ler do Vault:

```bash
kubectl -n todolist get externalsecret
kubectl -n todolist describe externalsecret todolist-app
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=50
```

- `permission denied` → policy ou role do Vault. Frequentemente é **mismatch de
  audience** entre o token que o ESO cunha via TokenRequest e o que a role espera.
- `connection refused` → o Vault está selado ou fora do ar (ver abaixo).

---

## O Vault está selado

```bash
kubectl -n vault exec vault-0 -- vault status     # exit 2 = selado
kubectl -n vault logs -l app=vault-unsealer --tail=20
```

O unsealer deveria resolver em ~10 s. Se não resolver:

```bash
kubectl -n vault get secret vault-unseal          # a chave existe?
kubectl -n vault exec vault-0 -- vault operator unseal "$(jq -r .unseal_keys_b64[0] .vault-keys.json)"
```

**Se `.vault-keys.json` se perdeu e o Vault está selado, não há recuperação.**
O caminho é apagar o PVC e rodar `just up` de novo — os valores-semente serão
regravados.

---

## Argo CD em `OutOfSync` permanente

### `caBundle` num webhook

cert-manager, ESO e CNPG escrevem `webhooks[].clientConfig.caBundle` em runtime.
O Argo CD vê isso como drift e tenta reverter, para sempre. A `Application`
precisa de `ignoreDifferences` no caminho — já está nos manifests; se aparecer
num componente novo, é isso.

### `/spec/replicas` do Deployment

O HPA e o Argo CD disputando o mesmo campo. Também já está tratado com
`ignoreDifferences`.

### `Application` presa em `Progressing`

```bash
kubectl -n argocd get applications.argoproj.io -o wide
argocd app get <nome> --grpc-web
```

Uma wave só avança quando a anterior está `Healthy`. Se a wave -10 (operators)
não subiu, nada depois dela vai subir. Comece pela wave mais baixa que estiver
vermelha.

---

## As telas `/pods` e `/cleanup/status` estão vazias

Três causas, nesta ordem de probabilidade:

1. **Mais de um CronJob no namespace.** `app.py` devolve `None` se a contagem
   não for exatamente 1. `kubectl -n todolist get cronjob` — precisa retornar 1.
2. **`automountServiceAccountToken: false`** em algum lugar. A aplicação lê o
   token da ServiceAccount para falar com a API.
3. **RBAC.** `kubectl -n todolist auth can-i list pods --as=system:serviceaccount:todolist:todolist`

O histórico de limpeza vazio, especificamente, costuma ser
`ttlSecondsAfterFinished`: o TTL controller apaga os pods dos Jobs, e é dos pods
que a tela é construída.

---

## Rotação de secret não surtiu efeito

```bash
kubectl -n todolist get secret todolist-app -o jsonpath='{.metadata.resourceVersion}'
kubectl -n todolist get externalsecret todolist-app -o jsonpath='{.status.refreshTime}'
kubectl -n reloader logs -l app=reloader --tail=20
```

- O ESO só relê a cada `refreshInterval` (1 min). Antes disso, nada acontece.
- Se o Secret mudou mas o pod não reiniciou: a anotação do Reloader precisa
  bater com o **nome exato** do Secret.
- Se o pod reiniciou mas o valor é o antigo: montagem com `subPath`. Não use.

`DB_PASSWORD` é caso especial — ver ADR 0004. Sem `spec.managed.roles`, rotacionar
a senha do banco é outage total.

---

## Nada funciona depois de um reboot

```bash
sysctl fs.inotify.max_user_instances     # precisa ser >= 512
docker ps | grep k3d
```

Se o valor voltou para 128, o `/etc/sysctl.d/99-k3d.conf` não foi aplicado.
Sintomas: "too many open files" em componentes aleatórios, k3s reiniciando
sozinho, pods presos em `ContainerCreating`. Nada aponta para inotify.

---

## Recomeçar do zero

```bash
just down
docker system prune -af --volumes    # se o disco estiver apertado
just up
```

`just down` apaga o `terraform.tfstate` de propósito: sem isso, o próximo
`terraform apply` tenta um refresh contra um API server que não existe mais.
