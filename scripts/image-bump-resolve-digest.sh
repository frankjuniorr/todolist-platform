#!/usr/bin/env bash
# ABOUTME: Valida o digest recebido do dispatch/workflow_dispatch e grava os
# ABOUTME: outputs (digest, branch) que os passos seguintes do image-bump usam.
set -euo pipefail

DIGEST="${1:?uso: $0 <digest>}"

case "$DIGEST" in
  sha256:*) ;;
  *) echo "::error::digest invalido: $DIGEST" >&2; exit 1 ;;
esac

echo "digest=$DIGEST" >> "$GITHUB_OUTPUT"
echo "branch=bump/${DIGEST#sha256:}" >> "$GITHUB_OUTPUT"
