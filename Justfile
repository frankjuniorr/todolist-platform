# ABOUTME: Fachada de UX. Cada receita e um comando que alguem vai digitar sob pressao.
# ABOUTME: O comando que importa e `just up`.

set shell := ["bash", "-uc"]

ansible_dir := justfile_directory() + "/ansible"
ns := "todolist"

_default:
    @just --list --unsorted

# --- Ciclo de vida -----------------------------------------------------------

# Instala as dependencias locais em versoes fixadas
setup:
    ./scripts/setup.sh

# Grava a URL do seu repositorio nos manifests (rodar UMA vez, depois commitar)
configure GITHUB_USER:
    ./scripts/configure.sh {{GITHUB_USER}}

# ESTE E O UNICO COMANDO. Do zero ate tudo no ar.
up:
    cd {{ansible_dir}} && ansible-playbook site.yml

# Destroi o cluster E o estado do Terraform
down:
    -k3d cluster delete todolist
    # Apagar o tfstate junto NAO e limpeza cosmetica: sem isso, o proximo
    # `terraform apply` tenta um refresh contra um API server que nao existe
    # mais e falha antes de conseguir criar qualquer coisa.
    -rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup
    -rm -f .vault-keys.json .argocd-admin .app-credentials .rendered-*.yaml

# Derruba e sobe de novo -- o teste real de reprodutibilidade
recreate: down up

# --- Observacao ---------------------------------------------------------------

# Estado geral do ambiente
status:
    @echo "=== nodes ==="        && kubectl get nodes
    @echo "=== applications ===" && kubectl -n argocd get applications.argoproj.io
    @echo "=== pods ({{ns}}) ===" && kubectl -n {{ns}} get pods
    @echo "=== hpa / pdb ==="    && kubectl -n {{ns}} get hpa,pdb
    @echo "=== postgres ==="     && kubectl -n {{ns}} get cluster.postgresql.cnpg.io
    @echo "=== externalsecrets ===" && kubectl -n {{ns}} get externalsecret
    @echo "=== invariante: exatamente 1 CronJob ==="
    @test "$(kubectl -n {{ns}} get cronjob --no-headers | wc -l)" -eq 1 \
      && echo "OK" \
      || echo "FALHOU -- /pods e /cleanup/status vao quebrar em silencio"

# URLs e credenciais de acesso
urls:
    @echo "aplicacao: https://todolist.localhost"
    @echo "argo cd:   https://argocd.localhost"
    @echo "vault:     https://vault.localhost"
    @echo
    @cat .app-credentials 2>/dev/null || echo "(sem .app-credentials -- rode 'just up')"
    @echo
    @cat .argocd-admin 2>/dev/null    || echo "(sem .argocd-admin)"

# Segue os logs da aplicacao
logs:
    kubectl -n {{ns}} logs -l app.kubernetes.io/name=todolist -f --tail=100

# --- Secrets ------------------------------------------------------------------

# Cria o vault.yml cifrado a partir do exemplo
secrets-init:
    @test -f .vault-pass || (openssl rand -base64 32 > .vault-pass && chmod 600 .vault-pass && echo "senha gerada em .vault-pass")
    cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
    ansible-vault encrypt --vault-password-file .vault-pass ansible/group_vars/all/vault.yml
    @echo "vault.yml cifrado. Pode ser commitado; .vault-pass NAO."

# Edita os valores-semente cifrados
secrets-edit:
    ansible-vault edit --vault-password-file .vault-pass ansible/group_vars/all/vault.yml

# Rotaciona um secret no Vault e observa o ESO + Reloader reagirem
secrets-rotate KEY="SESSION_KEY":
    #!/usr/bin/env bash
    set -euo pipefail
    NEW=$(openssl rand -hex 16)
    TOKEN=$(jq -r .root_token .vault-keys.json)
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$TOKEN" \
      vault kv patch secret/todolist/app {{KEY}}="$NEW"
    echo "novo valor gravado no Vault. Acompanhe a propagacao:"
    echo "  ESO reescreve o Secret em ate 1m (refreshInterval)"
    echo "  Reloader ve a mudanca e reinicia o Deployment"
    kubectl -n {{ns}} get pods -w

# --- Demonstracao -------------------------------------------------------------

# Gera carga em /login ate o HPA escalar
demo-scale:
    @echo "observe em outro terminal: kubectl -n {{ns}} get hpa -w"
    hey -z 90s -c 50 https://todolist.localhost/login

# Mata pods, drena um node e derruba o primario do Postgres
demo-chaos:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "--- matando um pod da aplicacao"
    kubectl -n {{ns}} delete pod -l app.kubernetes.io/name=todolist --wait=false | head -1
    echo "--- drenando um agent (o PDB precisa segurar em 1 indisponivel)"
    NODE=$(kubectl get nodes -o name | grep agent | head -1)
    kubectl drain "${NODE#node/}" --ignore-daemonsets --delete-emptydir-data --timeout=120s
    kubectl uncordon "${NODE#node/}"
    echo "--- derrubando o primario do Postgres"
    PRIMARY=$(kubectl -n {{ns}} get pods -l cnpg.io/instanceRole=primary -o name | head -1)
    kubectl -n {{ns}} delete "$PRIMARY"
    echo "--- selando o Vault (o unsealer deve reabrir em ~10s)"
    kubectl -n vault exec vault-0 -- vault operator seal || true
    sleep 20
    kubectl -n vault exec vault-0 -- vault status || true

# --- Qualidade ----------------------------------------------------------------

# Valida chart, manifests, terraform e ansible
lint:
    helm lint charts/todolist
    helm template t charts/todolist | kubeconform -strict -ignore-missing-schemas -summary
    helm template t charts/todolist | kube-linter lint - || true
    terraform -chdir=terraform fmt -check
    terraform -chdir=terraform validate
    ansible-lint ansible/
    shellcheck scripts/*.sh

# Sobe do zero, valida ponta a ponta e derruba
e2e:
    ./scripts/e2e.sh

# --- Acesso -------------------------------------------------------------------

# Instala a CA interna no trust store do sistema (tira o aviso do navegador)
trust-ca:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl -n cert-manager get secret todolist-ca-key-pair \
      -o jsonpath='{.data.tls\.crt}' | base64 -d | sudo tee /usr/local/share/ca-certificates/todolist-ca.crt >/dev/null
    sudo update-ca-certificates
    echo "Firefox e Chrome usam trust stores proprios (NSS). Para eles:"
    echo "  certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n todolist-ca -i /usr/local/share/ca-certificates/todolist-ca.crt"

# Escreve os hostnames em /etc/hosts (alternativa se *.localhost nao resolver)
hosts:
    #!/usr/bin/env bash
    set -euo pipefail
    for h in todolist argocd vault; do
      grep -q "$h.localhost" /etc/hosts || echo "127.0.0.1 $h.localhost" | sudo tee -a /etc/hosts
    done
    echo "/etc/hosts atualizado"

# Roteiro completo da apresentacao, encadeado
demo: status
    @echo; echo ">>> 1. GitOps: edite APP_COLOR em charts/todolist/values.yaml, commite e observe"
    @echo ">>> 2. self-heal:  kubectl -n {{ns}} scale deploy/todolist --replicas=1"
    @echo ">>> 3. escala:     just demo-scale"
    @echo ">>> 4. caos:       just demo-chaos"
    @echo ">>> 5. rotacao:    just secrets-rotate SESSION_KEY"

# Coleta estado e logs para docs/evidence/
evidence:
    #!/usr/bin/env bash
    set -euo pipefail
    OUT=docs/evidence/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
    kubectl get nodes -o wide                          > "$OUT/nodes.txt"
    kubectl get pods -A -o wide                        > "$OUT/pods.txt"
    kubectl -n argocd get applications.argoproj.io -o wide > "$OUT/applications.txt"
    kubectl -n {{ns}} get hpa,pdb,cronjob,externalsecret  > "$OUT/app-resources.txt"
    kubectl -n {{ns}} get cluster.postgresql.cnpg.io -o yaml > "$OUT/postgres.yaml"
    echo "coletado em $OUT"
