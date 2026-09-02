#!/usr/bin/env bash
# ABOUTME: Grava o usuario do GitHub nos manifests. Roda uma vez, o resultado e commitado.
set -euo pipefail

USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "uso: ./scripts/configure.sh <usuario-github>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# Por que isto e um passo separado e nao uma variavel do playbook:
#
# O Argo CD le os Applications filhos direto do Git. Uma substituicao feita em
# tempo de execucao existiria apenas nesta maquina; o que chega ao Argo CD e o
# que esta commitado. Entao a URL precisa estar NO REPOSITORIO -- e o unico jeito
# honesto e gravar e commitar.
mapfile -t FILES < <(grep -rl 'PLACEHOLDER_REPO_URL\|CHANGEME' \
  gitops charts ansible/group_vars README.md 2>/dev/null || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "nada a substituir -- ja configurado."
  exit 0
fi

for f in "${FILES[@]}"; do
  sed -i \
    -e "s#PLACEHOLDER_REPO_URL#https://github.com/${USER_NAME}/todolist-platform.git#g" \
    -e "s#CHANGEME#${USER_NAME}#g" \
    "$f"
  echo "  atualizado: $f"
done

echo
echo "Pronto. Agora commite e publique antes de rodar 'just up':"
echo "  git add -A && git commit -m 'configura repositorio gitops' && git push"
