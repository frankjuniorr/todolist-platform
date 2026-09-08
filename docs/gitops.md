# GitOps

## O modelo

O Argo CD tem exatamente um trabalho: **fazer o cluster parecer com o Git**.

```
Git (estado desejado)  ──── compara ────  Cluster (estado real)
                              │
                         divergiu? aplica.
```

Consequência prática: depois do bootstrap, **ninguém faz `kubectl apply`**. Toda
mudança de plataforma ou de aplicação é um commit, e o `git log` é o histórico de
mudanças do ambiente.

## App-of-Apps

Uma única `Application` raiz aponta para o diretório `gitops/apps/`, que contém
as demais. Aplicar a raiz faz a árvore inteira aparecer.

```
gitops/
├── root-app.yaml               ← o único manifesto aplicado imperativamente
├── apps/
│   ├── 00-namespaces.yaml
│   ├── 10-cert-manager.yaml
│   ├── 20-issuers.yaml
│   ├── 30-external-secrets.yaml
│   ├── 31-cloudnative-pg.yaml
│   ├── 32-reloader.yaml
│   ├── 40-secret-store.yaml
│   └── 50-todolist.yaml
└── manifests/
    ├── namespaces/
    ├── issuers/
    └── secret-store/
```

A raiz carrega o finalizer `resources-finalizer.argocd.argoproj.io`. Sem ele,
deletar a Application raiz deixaria órfãos todos os recursos filhos.

## Sync waves

O Argo CD aplica os recursos em ordem crescente de wave e **espera a wave
anterior ficar Healthy** antes de avançar. É assim que a dependência é declarada
— não há `depends_on`.

| Wave | Conteúdo | Por que aqui |
|---|---|---|
| **-20** | Namespaces, com labels de Pod Security Admission | tudo precisa de namespace |
| **-15** | cert-manager (`crds.enabled: true`) | instala os CRDs `Issuer`/`Certificate` |
| **-12** | `Certificate` root-CA + `ClusterIssuer` do tipo `ca` | **só é possível depois da wave anterior** |
| **-10** | External Secrets Operator, CloudNativePG, Reloader | instalam os CRDs que a app usa |
| **-5** | `ClusterSecretStore` | precisa do CRD e do webhook do ESO de pé |
| **0** | chart da aplicação | com waves internas: `-3` ExternalSecrets, `-2` Cluster do CNPG |

### Um erro que só aparece na execução

O `ClusterIssuer` selfSigned tinha sido colocado junto com os namespaces, na wave
-20. Faz sentido intuitivamente — é a raiz da cadeia de confiança, então vem
primeiro.

Mas `ClusterIssuer` é um **CRD do cert-manager**, que só é instalado na wave -15.
Aplicar o objeto na wave -20 falha com `no matches for kind "ClusterIssuer"`.
Ordem impossível: o emissor não pode preceder quem define o que é um emissor.

Corrigido para a wave -12, junto com o `Certificate` da CA raiz.

### Waves dentro do chart da aplicação

O chart inteiro é a wave 0 do ponto de vista da raiz, mas tem ordem interna:

```
-3   ExternalSecret todolist-app  e  todolist-db
-2   Cluster do CloudNativePG           (precisa do Secret basic-auth existir)
 0   Deployment, Service, Ingress, HPA, PDB, CronJob
```

O gate real da wave -3 não é a wave em si, mas o **health check nativo do Argo CD
para `ExternalSecret`**, que só marca Healthy quando a condição `SecretSynced` é
`True`. A wave sozinha garantiria apenas que o objeto foi criado — não que o
Secret existe.

## `ignoreDifferences` — a armadilha do `caBundle`

cert-manager, ESO e CloudNativePG injetam o certificado da própria CA dentro dos
seus objetos de webhook, **em tempo de execução**. Esse campo não existe no chart.

Sem tratamento, o ciclo é:

```
Argo CD vê a diferença → Application OutOfSync
   → selfHeal apaga o caBundle
      → o webhook para de funcionar
         → o cainjector reescreve
            → Argo CD vê a diferença de novo
```

Um loop que degrada o cluster. A correção é declarar o campo como não-comparável:

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jsonPointers: ["/webhooks/0/clientConfig/caBundle"]
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jsonPointers: ["/webhooks/0/clientConfig/caBundle"]
```

Isso está em todas as Applications que instalam operators com webhook.

## Outras opções de sync usadas

| Opção | Onde | Por quê |
|---|---|---|
| `ServerSideApply=true` | cert-manager, CNPG | os CRDs passam de 256 KB, e o apply client-side estoura o limite da anotação `last-applied-configuration` |
| `SkipDryRunOnMissingResource=true` | Applications de CRs | o dry-run falha quando o CRD ainda não existe no momento do plan |
| `CreateNamespace=true` | todas | evita ordenação manual de namespace |
| `retry` com backoff exponencial | todas | ver abaixo |

## Retry, e por que ele não é opcional

```yaml
retry:
  limit: 10
  backoff: { duration: 10s, factor: 2, maxDuration: 5m }
```

O primeiro reconcile de um cluster novo **falha por natureza**: CRDs, webhooks e
Secrets aparecem numa ordem que não dá para prever completamente. Um webhook que
ainda não subiu recusa a conexão; um CR aplicado meio segundo cedo demais falha
com `x509`.

A estratégia não é evitar essas falhas — é torná-las auto-recuperáveis. Isto é o
que faz `just up` funcionar de forma confiável numa máquina que nunca rodou o
projeto.

## Self-heal e prune

```yaml
automated: { prune: true, selfHeal: true }
```

- **selfHeal** — divergência causada por `kubectl` é revertida em segundos.
- **prune** — remover um arquivo do Git remove o recurso do cluster.

Demonstração de 30 segundos:

```bash
kubectl -n todolist scale deploy todolist --replicas=5
kubectl -n todolist get deploy todolist -w      # volta sozinho
```

## Argo CD atrás do Traefik

Duas configurações necessárias, cada uma com um sintoma característico:

**`configs.params."server.insecure": true`.** O Traefik termina o TLS; sem isso o
Argo CD redireciona para HTTPS de novo e o browser mostra
`ERR_TOO_MANY_REDIRECTS`.

**`--grpc-web` no CLI.** O gRPC puro não atravessa o proxy:

```bash
argocd app list --grpc-web
argocd app sync todolist --grpc-web
```

## Comandos

```bash
kubectl -n argocd get applications.argoproj.io
argocd app get todolist --grpc-web
argocd app diff todolist --grpc-web       # por que está OutOfSync
argocd app sync todolist --grpc-web       # sem esperar o polling de 3 min
```

A UI fica em `https://argocd.localhost`; a senha inicial é exibida por
`just urls`.
