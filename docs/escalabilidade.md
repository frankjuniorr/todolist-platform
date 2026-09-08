# Escalabilidade e resiliência

Cada objeto aqui responde a uma pergunta específica, e cada configuração fora do
default tem um motivo.

## HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  behavior:
    scaleUp:   { stabilizationWindowSeconds: 30 }
    scaleDown: { stabilizationWindowSeconds: 300 }
```

`minReplicas: 2` — uma réplica não sobrevive a um rolling update sem
indisponibilidade, e não há o que o PDB proteja.

`behavior` assimétrico: subir rápido (30 s) porque o custo de demorar é
degradação percebida; descer devagar (300 s) porque descer cedo demais gera
*flapping* — escala, cai, escala de novo, e o serviço passa o tempo todo em
transição.

O `metrics-server` já vem no k3s. Num kind seria preciso instalar.

### O HPA depende de `requests`

```yaml
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { memory: 256Mi }        # sem limit de CPU, de propósito
```

**Sem `requests.cpu` o HPA reporta `<unknown>` e nunca escala.** A métrica é
utilização *relativa ao request*; sem denominador não há fração. É o erro mais
comum com HPA, e o sintoma é um objeto que existe e não faz nada.

**Não há limit de CPU, deliberadamente.** O throttling do CFS distorce
exatamente a métrica que o HPA lê: o pod é estrangulado, o uso aparece alto, o
HPA escala, e os pods novos são estrangulados também. `requests` sem `limits` de
CPU é a recomendação para workload sensível a latência.

Memória tem limit, porque memória não é compressível — sem limit, um vazamento
derruba o nó inteiro em vez de apenas o pod.

### Demonstração

```bash
just demo-scale                    # hey -z 60s -c 50 em /login
kubectl -n todolist get hpa -w
```

## PodDisruptionBudget

```yaml
spec:
  maxUnavailable: 1
```

O PDB protege contra **disrupções voluntárias** — `kubectl drain`, upgrade de nó,
descomissionamento. Não protege contra crash: o kubelet não consulta PDB para
reiniciar um contêiner que morreu.

**`maxUnavailable: 0` é o erro clássico** e parece mais seguro. Ele torna
qualquer drain impossível para sempre, e o sintoma é um upgrade de nó pendurado
sem explicação.

```bash
kubectl drain k3d-todolist-agent-0 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon k3d-todolist-agent-0
```

## Topology spread

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    matchLabelKeys: [pod-template-hash]
```

`ScheduleAnyway` e não `DoNotSchedule`: a segunda transforma a distribuição em
obrigação, e se um nó cair os pods novos ficam `Pending` — uma indisponibilidade
causada pela regra que deveria aumentar a disponibilidade.

`matchLabelKeys: [pod-template-hash]` faz o cálculo considerar apenas os pods da
mesma revisão. Sem isso, durante um rolling update os pods velhos contam para o
skew e a distribuição fica errada exatamente quando importa.

**Isto aqui é teatro, e é importante dizer.** Os quatro "nós" são contêineres num
único host, com um kernel e um daemon do Docker. Espalhar réplicas entre eles não
produz tolerância a falha de infraestrutura. O que a configuração demonstra é que
os objetos estão corretos e o comportamento é o esperado — num cluster com nós de
verdade, funcionaria de verdade.

## Probes

Três probes, três perguntas diferentes:

| Probe | Endpoint | Pergunta | Config |
|---|---|---|---|
| `startupProbe` | `/healthz` | já terminou de subir? | `period: 5`, `failureThreshold: 30` (150 s) |
| `readinessProbe` | `/healthz` | posso receber tráfego? | `period: 5`, `failureThreshold: 2` |
| `livenessProbe` | **`/login`** | o processo travou? | `period: 10`, `failureThreshold: 3` |

### Por que o liveness não usa `/healthz`

`/healthz` faz `SELECT 1` no banco. Se ele fosse o liveness probe, uma queda de
banco mataria **todos** os pods simultaneamente. Eles entrariam em
`CrashLoopBackOff`, cujo backoff cresce até 5 minutos — e quando o banco voltasse,
a aplicação ainda passaria minutos fora do ar. **Uma indisponibilidade criada
pela própria probe.**

`GET /login` renderiza um template sem tocar no banco. É a pergunta certa para
liveness: *o processo está travado?*

E `/healthz` continua sendo o readiness, que é onde a informação "o banco caiu"
deve agir — tirar o pod do Service sem matá-lo. Quando o banco volta, o pod volta
ao Service em segundos, sem restart.

O `startupProbe` existe para desacoplar o boot lento (o `create_all()` roda no
import) da detecção de travamento: sem ele, ou o liveness é tolerante demais em
regime, ou mata o pod durante o boot.

## `preStop` e terminação graciosa

```yaml
lifecycle:
  preStop: { exec: { command: ["sleep", "5"] } }
terminationGracePeriodSeconds: 30
```

Quando um pod entra em `Terminating`, duas coisas acontecem **em paralelo**: o
kubelet envia SIGTERM, e o endpoint controller remove o pod dos endpoints do
Service. A segunda propaga pelo kube-proxy de todos os nós e leva algum tempo.

Sem o `sleep 5`, o processo termina antes da remoção completar, e conexões
roteadas nessa janela recebem 502. Isso aparece como "502 esporádico em todo
rolling update" — e vira `imagePullPolicy`, `resources`, qualquer coisa menos a
causa real.

## Estratégia de rollout

```yaml
strategy:
  rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
```

`maxUnavailable: 0` — nunca reduz a capacidade durante o update. Combinado com
`maxSurge: 1`, sobe um pod novo, espera ficar Ready, remove um velho.

Note que este `maxUnavailable` é do Deployment, e nada tem a ver com o do PDB.
Coincidência de nome, semânticas diferentes.

## Gunicorn: 1 worker, 8 threads

```
--workers 1 --threads 8 --worker-class gthread --timeout 60
```

Isto não é limitação, é consequência de um fato do código: **`db.create_all()`
roda no import do módulo**. Com N workers subindo juntos contra um banco vazio,
há N processos criando as mesmas tabelas ao mesmo tempo — `DuplicateTable`
intermitente. O pior tipo de bug: some quando se vai investigar.

Com um worker, a race não existe dentro do pod. A escala é horizontal, via HPA —
que é a resposta nativa do Kubernetes.

A alternativa (`--preload` com `db.engine.dispose()` no hook `post_fork`) está
documentada no [ADR 0009](adr/0009-gunicorn-um-worker.md). Sem o `dispose()`, os
processos filhos herdam sockets do pool do processo master e corrompem conexões
— outro bug intermitente.

## O CronJob de limpeza

A aplicação não remove tarefas concluídas sozinha; a limpeza é acionada de fora,
por `POST /cleanup` com o token no header.

```yaml
schedule: "*/5 * * * *"
concurrencyPolicy: Forbid
successfulJobsHistoryLimit: 10
failedJobsHistoryLimit: 5
restartPolicy: Never
# ttlSecondsAfterFinished: OMITIDO de propósito
```

### O invariante: exatamente um CronJob no namespace

Isto é um fato do código da aplicação, não uma escolha:

```python
# _cleanup_cronjob() devolve None se o namespace não tiver exatamente 1 CronJob
```

Com zero ou dois CronJobs, as telas `/cleanup/status` e a suspensão do
agendamento param de funcionar — **sem erro visível**. Um CronJob de backup no
mesmo namespace derrubaria duas funcionalidades.

Como isso é invisível para quem for mexer depois, virou verificação automatizada
em três lugares: no job `invariantes` do CI, no papel `gitops_bootstrap` e no
`just status`.

### Por que `ttlSecondsAfterFinished` é omitido

A tela de histórico lê os **pods** dos Jobs e os logs deles. O TTL controller
apaga Job e pods juntos, **independentemente** de `successfulJobsHistoryLimit` —
e a tela fica vazia. Os defaults (`3` e `1`) também são baixos demais para
produzir histórico visível; daí `10` e `5`.

### Outros detalhes

`restartPolicy: Never` — com `OnFailure` o pod reinicia in-place e o log anterior
é sobrescrito. Com `Never`, cada tentativa é um pod, e as falhas ficam visíveis.

**Alvo é o Service ClusterIP, não o Ingress.** Tráfego interno pelo caminho mais
curto: sem dependência de DNS externo, TLS ou Traefik.

**Monta apenas `CLEANUP_TOKEN`.** Pelo `items` do volume, o pod do CronJob nunca
vê `DB_PASSWORD` nem `SESSION_KEY`.

**A saída precisa ser exatamente `deleted N`.** O badge da interface faz
`result.startswith("deleted")` — qualquer ruído no stdout quebra a tela. Daí
`curl -sS`.

## RBAC — o mínimo exato

A aplicação chama a API do Kubernetes nas telas `/pods` e `/cleanup/status`. As
permissões foram derivadas linha a linha das chamadas do código:

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["batch"]
    resources: ["cronjobs"]
    verbs: ["list", "patch"]
```

Sem `get` em pod nomeado (a aplicação sempre lista), sem `watch`, sem `update`
(o patch é merge-patch), sem nada cluster-scoped, sem ClusterRole.

**`automountServiceAccountToken` precisa continuar `true`.** Vários baselines de
hardening desligam isso por padrão — e aí `/pods` e `/cleanup/status` quebram sem
erro claro.

## Contexto de segurança

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile: { type: RuntimeDefault }

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
```

`fsGroup: 10001` não é decorativo: é o que faz os arquivos de secret montados com
`0440` serem legíveis pelo processo. Ver [Secrets](secrets.md).

`readOnlyRootFilesystem: true` exige um `emptyDir` montado em `/tmp` — o gunicorn
e o Python precisam de local gravável.

## Demonstrando tudo

```bash
just demo-chaos
```

Encadeia: mata pods (o Service segue respondendo), drena um nó (o PDB é
respeitado), mata o primário do Postgres (failover em ~10 s), e sela o Vault (o
unsealer recupera em ~10 s).
