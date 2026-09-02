#!/usr/bin/env bash
# ABOUTME: Prova executavel de que "um comando sobe tudo" nao e promessa de README.
# ABOUTME: Sobe do zero, valida os cinco requisitos e derruba.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FALHOU: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== derrubando qualquer ambiente anterior"
just down >/dev/null 2>&1 || true

echo "== subindo do zero (R1: provisionamento por codigo)"
time just up

echo "== R2: deployment automatizado"
kubectl -n argocd get applications.argoproj.io -o json \
  | jq -e '[.items[] | select(.status.health.status != "Healthy")] | length == 0' >/dev/null \
  || fail "ha Applications fora de Healthy"
ok "todas as Applications Healthy"

echo "== R3: acesso externo pelo navegador"
# --insecure porque a CA e self-signed e o runner nao a instalou no trust store.
code=$(curl -sk -o /dev/null -w '%{http_code}' https://todolist.localhost/login)
[[ "$code" == "200" ]] || fail "/login respondeu $code"
ok "https://todolist.localhost/login -> 200"

curl -sk https://todolist.localhost/healthz | grep -q '^ok$' || fail "/healthz nao respondeu ok"
ok "/healthz -> ok (banco acessivel)"

echo "== R4: escalabilidade e resiliencia"
kubectl -n todolist get hpa todolist -o json \
  | jq -e '.status.currentMetrics != null' >/dev/null \
  || fail "o HPA nao esta lendo metricas (falta requests.cpu?)"
ok "HPA lendo metricas"

kubectl -n todolist get pdb todolist >/dev/null || fail "PDB ausente"
ok "PDB presente"

replicas=$(kubectl -n todolist get cluster.postgresql.cnpg.io -o jsonpath='{.items[0].status.readyInstances}')
[[ "$replicas" -ge 1 ]] || fail "nenhuma instancia de Postgres pronta"
ok "postgres com $replicas instancias prontas"

echo "== invariante do CronJob unico"
n=$(kubectl -n todolist get cronjob --no-headers | wc -l)
[[ "$n" -eq 1 ]] || fail "esperado 1 CronJob, encontrado $n"
ok "exatamente 1 CronJob"

echo "== nenhum secret em claro no Git"
! git grep -qiE 'BEGIN (RSA|EC) PRIVATE KEY' -- . || fail "chave privada commitada"
ok "sem chave privada no historico rastreado"

echo
echo "TUDO VERDE."
