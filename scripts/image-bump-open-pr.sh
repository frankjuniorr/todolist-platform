#!/usr/bin/env bash
# ABOUTME: Comita o bump numa branch, abre o PR e liga o auto-merge.
# ABOUTME: Roda com GITHUB_TOKEN de proposito -- ver o comentario no workflow.
set -euo pipefail

BRANCH="${1:?uso: $0 <branch> <digest>}"
DIGEST="${2:?uso: $0 <branch> <digest>}"

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "$BRANCH"
git commit -am "bump todolist para $DIGEST"
git push -u origin "$BRANCH"

# Cria o label se ainda nao existir -- um `gh repo create` novo nao vem com
# ele, e depender de alguem criar na mao pela UI quebraria a reprodutibilidade
# na primeira vez que este workflow rodasse num repositorio novo.
gh label create automated --color 0e8a16 --description "Aberto automaticamente por um workflow" 2>/dev/null || true

gh pr create \
  --title "bump todolist para $DIGEST" \
  --body "Digest publicado por \`todolist-app\`. O Argo CD sincroniza apos o merge." \
  --label automated

# auto-merge respeita branch protection: o PR so entra depois que os checks
# obrigatorios passam. Cada merge vira um registro de deploy auditavel no git log.
gh pr merge --auto --squash
