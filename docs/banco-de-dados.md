# Banco de dados

PostgreSQL gerenciado pelo **CloudNativePG**, três instâncias, failover
automático.

## Por que um operator, e não um StatefulSet

Um StatefulSet entrega os pods e os volumes. Não entrega replicação, promoção de
réplica, nem redirecionamento de tráfego após failover — isso seria código nosso,
e é justamente a parte difícil.

O CloudNativePG entrega:

- replicação streaming configurada;
- failover automático em ~10 segundos;
- três Services, sendo que `-rw` aponta **sempre para o primário atual**;
- rolling update das instâncias com switchover controlado;
- backup para object storage via CRD `ScheduledBackup` (não configurado aqui —
  não há bucket).

Os charts Bitnami de PostgreSQL foram descartados por outro motivo: a mudança de
política de imagens em 2025 tornou as tags antigas indisponíveis, o que é
incompatível com um ambiente que precisa subir igual daqui a seis meses.

## Declaração

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: todolist-pg
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  primaryUpdateStrategy: unsupervised
  enableSuperuserAccess: false
  bootstrap:
    initdb:
      database: todolist
      owner: todolist
      secret: { name: todolist-db }
  managed:
    roles:
      - name: todolist
        login: true
        passwordSecret: { name: todolist-db }
  storage:
    size: 1Gi
    storageClass: local-path
```

**Wave -2**, depois dos `ExternalSecret` (wave -3): o Secret `todolist-db`
precisa existir antes de o bootstrap acontecer.

`enableSuperuserAccess: false` — sem isso o operator cria e gerencia um Secret
de superusuário próprio, e passa a haver credencial fora do fluxo do Vault.

`primaryUpdateStrategy: unsupervised` — o operator faz switchover sozinho em
upgrade de versão, sem aprovação manual.

## O contrato do Secret

O CNPG exige um Secret do tipo `kubernetes.io/basic-auth`, que aceita
exatamente dois campos: `username` e `password`. A aplicação, por outro lado,
quer arquivos chamados `DB_USER` e `DB_PASSWORD`.

A solução são **dois `ExternalSecret` lendo o mesmo caminho do Vault**:

| ExternalSecret | Secret gerado | Tipo | Consumidor |
|---|---|---|---|
| `todolist-db` | `todolist-db` | `kubernetes.io/basic-auth` | CloudNativePG |
| `todolist-app` | `todolist-app` | `Opaque`, com `username` → `DB_USER` | a aplicação |

Um valor no Vault, dois consumidores com contratos incompatíveis, e nenhuma
duplicação da verdade. Com Secret versionado no Git, o mesmo valor estaria em dois
manifestos — e eles divergiriam na primeira rotação.

**O `owner` do `initdb` precisa ser idêntico ao `username` do Secret.** Se
divergirem, o banco é criado com um dono que não é o usuário cuja senha está
configurada, e a aplicação recebe `permission denied for schema public` — um erro
que aponta para permissão de schema, não para configuração de bootstrap.

## Como a aplicação encontra o banco

```
DB_HOST = todolist-pg-rw     (via ConfigMap)
```

Os três Services criados pelo operator:

| Service | Aponta para |
|---|---|
| `todolist-pg-rw` | o primário atual |
| `todolist-pg-ro` | apenas réplicas |
| `todolist-pg-r` | qualquer instância |

A aplicação usa `-rw` e nunca precisa saber qual pod é o primário. Depois de um
failover, o operator reaponta o Service e o tráfego segue.

## O initContainer

```yaml
initContainers:
  - name: wait-for-db
    image: ghcr.io/cloudnative-pg/postgresql:16.4
    command: ["sh", "-c", "until psql -qtAc 'select 1'; do sleep 2; done"]
```

Isto existe por causa de um fato do código da aplicação: **`db.create_all()` roda
no import do módulo**. Se o banco não estiver acessível no momento do boot, o
processo morre.

Sem o initContainer, o sintoma seria `CrashLoopBackOff` — que parece bug de
aplicação e leva a investigar o lugar errado. Com ele, o sintoma é `Init:0/1`,
que se lê como "esperando dependência". O log do initContainer diz exatamente o
que está faltando.

Repare que o teste é `psql -c 'select 1'`, e não um TCP check. Autenticar de
verdade é o que valida a credencial — um socket aberto não prova que a senha
está certa.

## Failover

```bash
kubectl cnpg status -n todolist todolist-pg
kubectl -n todolist delete pod todolist-pg-1        # o primário
kubectl cnpg status -n todolist todolist-pg
```

O operator promove uma réplica e reaponta o Service `-rw`. Leva cerca de 10
segundos.

A aplicação não se recupera instantaneamente, e o motivo está no código dela:
não há `pool_pre_ping` configurado no SQLAlchemy, então as conexões que já estavam
no pool ficam *stale* por até ~30 segundos até serem descartadas.

## Rotação de credencial

Este é o ponto mais delicado do banco, e a razão de a demonstração de rotação
usar `SESSION_KEY` e não `DB_PASSWORD`.

`bootstrap.initdb` roda **uma única vez**, na criação do cluster. Se você trocar a
senha no Vault e o CNPG só souber do `initdb`, o resultado é: senha nova no
Secret, senha antiga no banco, aplicação sem acesso. Outage total, e o Secret
parece correto.

`spec.managed.roles` é o mecanismo certo: o operator reconcilia a senha da role
continuamente a partir do Secret. Com ele declarado, rotacionar `DB_PASSWORD`
funciona — mas depende de o operator ter aplicado a mudança **antes** de a
aplicação reiniciar, e essa janela é real.

## Armazenamento

`storageClass: local-path` — o provisioner padrão do k3s, que cria PVs como
diretórios no disco do nó.

Consequência importante: **os PVs são node-affine**. O pod que usa um PV não pode
ser reagendado em outro nó. Num cluster real isso seria resolvido com storage de
rede; aqui é uma limitação aceita, e é parte do motivo de a resiliência
demonstrada ser de mecânica, não de infraestrutura.

## O que não está aqui

**Backup.** O CNPG suporta `ScheduledBackup` para S3-compatível, e não há bucket
neste ambiente. Vale notar que `ScheduledBackup` é um CRD e **não** cria um
CronJob — o que é sorte, porque um CronJob extra no namespace quebraria duas
telas da aplicação (ver [Escalabilidade](escalabilidade.md#o-cronjob-de-limpeza)).

**Pooler.** O CNPG tem um CRD `Pooler` (PgBouncer). Com dois a seis pods de
aplicação e um worker cada, não há pressão de conexões que justifique.
