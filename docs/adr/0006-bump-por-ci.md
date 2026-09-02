# ADR 0006 — Bump de imagem por CI, não pelo Argo CD Image Updater

**Status:** aceito

## Contexto

"As atualizações da aplicação devem ser automáticas." O GitOps resolve **metade**
disso: o Argo CD garante que o cluster reflete o Git. Ele não decide que existe
uma imagem nova. Alguém precisa escrever o digest novo no Git.

## Decisão

O CI da aplicação publica a imagem e dispara um `repository_dispatch` para o repo
de plataforma, que atualiza `image.digest` em `charts/todolist/values.yaml` e
abre um PR com auto-merge. O Argo CD sincroniza depois do merge.

## Consequências

- O `git log` do repositório de plataforma vira um **registro de deploy**: cada
  `bump todolist para sha256:...` é um evento datado, atribuído e reversível com
  `git revert`.
- Branch protection se aplica: o bump passa pelos mesmos checks que qualquer
  mudança (`helm template | kubeconform`).
- Demonstrável ao vivo, sem caixa-preta de polling.
- Custa três detalhes de GitHub que só aparecem quando quebram:
  - `GITHUB_TOKEN` **não dispara workflow em outro repositório** → o dispatch
    precisa de um PAT fine-grained.
  - Mas o commit de bump usa `GITHUB_TOKEN` justamente porque pushes com ele
    **não** disparam `on: push` — é a prevenção de loop nativa. Um PAT ali
    criaria a cascata.
  - Bump do **digest**, nunca da tag. Uma tag pode ser reescrita apontando para
    outro conteúdo.

## Alternativas descartadas

**Argo CD Image Updater.** Resolveria em três anotações. Descartado por dois
motivos concretos: o modo `write-back-method: argocd` **muta a spec da
Application viva**, e o Git deixa de ser a fonte da verdade — o oposto do ponto
de usar GitOps; e com tags por SHA a estratégia `semver` não funciona, exigindo
`newest-build` ou uma tag mutável de referência, que reintroduz o problema que o
digest resolvia.

**`imagePullPolicy: Always` com `:latest`.** Não é atualização automática, é
imprevisibilidade automática: dois pods do mesmo ReplicaSet podem rodar builds
diferentes, e não há como saber qual.
