#!/usr/bin/env bash
# ABOUTME: Grava o digest novo em values.yaml e sinaliza (output "changed") se
# ABOUTME: houve mudanca de verdade -- para o job pular o PR quando nao ha.
set -euo pipefail

DIGEST="${1:?uso: $0 <digest>}"

# Bump do DIGEST, nao da tag. Uma tag pode ser reescrita apontando para outro
# conteudo; o digest e o hash do manifesto. `:latest` com
# imagePullPolicy: IfNotPresent e a receita para "atualizei e nao mudou".
sed -i "s|^  digest: .*|  digest: \"${DIGEST}\"|" charts/todolist/values.yaml

# Passos `run:` do GitHub Actions usam `bash -e` por padrao. Um
# `git diff --exit-code && { ...; exit 0; }` como linha solta e armadilha:
# quando HA diferenca (o caso normal, o que queremos processar), o comando
# da esquerda retorna 1, e e exatamente esse 1 que o `-e` usa para abortar o
# script -- antes mesmo do commit acontecer. Por isso `if`, nao `&&`.
if git diff --quiet; then
  echo "digest ja atual"
  echo "changed=false" >> "$GITHUB_OUTPUT"
else
  echo "changed=true" >> "$GITHUB_OUTPUT"
fi
