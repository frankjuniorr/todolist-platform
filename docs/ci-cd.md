# CI/CD e atualização automática

São **duas** pipelines em dois repositórios, e a fronteira entre elas é a
resposta a uma pergunta que costuma ser respondida errado.

## GitOps sozinho não atualiza a aplicação

O Argo CD garante que **o cluster reflete o Git**. Ele não sabe que existe uma
imagem nova — nada no Git mudou. Alguém precisa escrever o digest novo no
repositório, e é isso que a pipeline faz.

```
push em todolist-app
   │
   ├─ lint      hadolint · gitleaks (histórico completo) · trivy fs
   ├─ test      pytest contra um Postgres real (service container)
   │
   ├─ build     buildx amd64+arm64 → ghcr.io/<owner>/todolist-app
   │            trivy image · cosign keyless · SBOM syft
   │            saída: steps.build.outputs.digest
   │
   └─ notificar  repository_dispatch (type: nova-imagem) ──────┐
                                                               ▼
                                     todolist-platform / image-bump.yml
                                        sed no digest de charts/todolist/values.yaml
                                        PR + gh pr merge --auto --squash
                                                               ▼
                                            Argo CD auto-sync → rolling update
```

O `git log` do repositório de plataforma vira o histórico de deploys: cada
`bump todolist para sha256:…` é um registro auditável de o que subiu e quando.

## Digest, não tag

```yaml
image:
  repository: ghcr.io/<owner>/todolist-app
  digest: "sha256:…"     # atualizado pelo image-bump.yml
  tag: latest            # só usada quando digest está vazio (dev local)
```

Uma tag é um ponteiro mutável — pode ser reescrita apontando para outro
conteúdo. Um digest é o hash do manifesto e não pode mentir. A analogia direta é
branch versus commit SHA.

O antipadrão que isso elimina: `:latest` com `imagePullPolicy: IfNotPresent`. O
kubelet vê que já tem uma imagem chamada `latest` no nó e não puxa nada. O
sintoma é "atualizei e não mudou" — sem nenhum erro em lugar nenhum.

Com digest, o campo `image` **muda de valor** a cada release. O Deployment muda,
o ReplicaSet muda, o rolling update acontece. Não é preciso `imagePullPolicy:
Always`, e o rollback é `git revert`.

## As quatro armadilhas de token e loop

Estas quatro consomem meio dia cada quando descobertas tarde.

**1. `GITHUB_TOKEN` não dispara workflow em outro repositório.** É prevenção de
loop infinito, por design. O `repository_dispatch` entre repos precisa de um PAT
fine-grained — é a única etapa do fluxo que exige token de usuário, com escopo
`contents: write` só no repositório de plataforma.

**2. Mas o commit do bump usa `GITHUB_TOKEN` justamente por isso.** Pushes feitos
com ele não disparam `on: push`. Se o bump usasse o PAT, o commit dispararia o
CI da plataforma, que poderia disparar outro bump — cascata. Aqui a limitação é
a proteção.

**3. `concurrency: {group: image-bump}`.** Dois pushes seguidos na aplicação
gerariam dois bumps concorrentes no mesmo arquivo. Serializar é mais barato do
que resolver conflito.

**4. Branch protection e auto-merge.** O bot abre PR e chama `gh pr merge --auto
--squash`. O PR só entra quando os checks obrigatórios passam — o `helm template
| kubeconform` roda contra a imagem nova antes de ela chegar no cluster.

O workflow valida o formato do digest antes de qualquer coisa (`case "$DIGEST" in
sha256:*)`), e sai limpo se o digest já for o atual — um dispatch repetido não
gera PR vazio.

## O que ficou de fora: Argo CD Image Updater

Existe uma ferramenta que faria isso sem CI. Foi descartada:

- O modo `write-back-method: argocd` **muta a spec da Application viva**. O Git
  deixa de ser fonte da verdade, que é a única propriedade que justifica GitOps.
- Com tags por SHA, a estratégia `semver` não funciona; sobra `newest-build` ou
  `digest` com uma tag mutável de referência — de volta ao problema do `latest`.
- É polling opaco. O bump por CI aparece no `git log` e é demonstrável ao vivo.

Ver [ADR 0006](adr/0006-bump-por-ci.md).

## O CI da plataforma

Valida tudo o que dá para validar sem subir cluster:

| Job | Ferramentas |
|---|---|
| `lint` | gitleaks (`fetch-depth: 0`), shellcheck, actionlint, ansible-lint |
| `terraform` | `fmt -check`, `validate`, tfsec |
| `chart` | `helm lint`, `kubeconform -strict`, kube-linter, kubeconform no `gitops/` |
| `invariantes` | verificações que nenhum linter conhece |

`gitleaks` precisa de `fetch-depth: 0`: um segredo removido no último commit
continua recuperável em qualquer commit anterior. Varrer só o HEAD é teatro.

`kubeconform -ignore-missing-schemas` é obrigatório: os CRDs (`Cluster` do CNPG,
`ExternalSecret`) não estão no catálogo, e sem a flag todo CR vira erro.

### O job `invariantes`

Duas regras derivadas do código da aplicação e do comportamento do kubelet, que
nenhuma ferramenta genérica conhece:

```bash
# exatamente 1 CronJob — app.py exige isso (ver Escalabilidade)
n=$(helm template t charts/todolist | grep -c '^kind: CronJob$')
[ "$n" -eq 1 ] || exit 1

# nenhum subPath — montagens com subPath não são atualizadas na rotação
helm template t charts/todolist | grep -q 'subPath' && exit 1
```

Ambas protegem contra falhas **silenciosas**: quem adicionar um CronJob de backup
ou "arrumar" uma montagem com `subPath` não veria erro nenhum no cluster. O CI vê.

## `e2e.yml` — o job mais importante do repositório

```yaml
- run: ./scripts/setup.sh
- run: ./scripts/e2e.sh
- if: failure()   # diagnóstico: nodes, pods, applications, events, describe
- if: always()    # just down
```

Sobe o k3d dentro do runner, roda `just up` do zero, espera todas as Applications
ficarem `Healthy/Synced`, faz `curl` na aplicação e derruba tudo. **É a prova
executável de que "um comando sobe tudo" não é promessa de README.**

Roda em PR, semanalmente por cron, e sob demanda. O cron é o que importa a longo
prazo: pega quebra causada por versão nova de chart upstream, não por mudança
nossa. Um ambiente testado só quando alguém mexe nele descobre a quebra na hora
errada.

O passo de diagnóstico com `|| true` em cada comando é deliberado: um `describe`
que falha não pode esconder a saída dos comandos seguintes.

## Segurança na esteira

| Camada | Ferramenta |
|---|---|
| Segredos no histórico | gitleaks |
| Dependências e IaC | trivy fs, tfsec, checkov |
| Dockerfile | hadolint (`failure-threshold: warning`) |
| Imagem publicada | trivy image `--ignore-unfixed` |
| Procedência | cosign keyless (OIDC + Rekor), SBOM SPDX, provenance/SBOM do buildx |
| Manifestos | kube-linter, kubeconform |

**`--ignore-unfixed` não é preguiça.** CVE de sistema operacional sem correção
disponível não é acionável: deixaria o CI vermelho permanentemente e treinaria o
time a ignorar o sinal — que é pior do que não ter o scanner.

**cosign keyless** não tem chave privada para vazar: a identidade vem do token
OIDC do próprio workflow e a assinatura vai para o log público Rekor.

`permissions: contents: read` no topo de cada workflow, e cada job amplia só o
que precisa (`packages: write`, `id-token: write` apenas no job de build).

### Pinagem das actions

As actions estão referenciadas por **tag de versão**, com o Renovate configurado
com `helpers:pinGitHubActionDigests` para convertê-las em SHA no primeiro PR
depois que o repositório existir. Pinagem por SHA é a prática correta — uma tag
de action pode ser movida —, mas SHAs não podem ser inventados sem consultar o
upstream. O caminho está preparado, não fingido.

## Comandos

```bash
just lint                     # roda localmente o equivalente ao CI
just e2e                      # o ciclo completo local
gh workflow run image-bump.yml -f digest=sha256:...   # bump manual
```
