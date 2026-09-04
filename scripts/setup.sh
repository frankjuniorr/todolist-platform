#!/usr/bin/env bash
# ABOUTME: Instala as dependencias locais em versoes fixadas. Idempotente.
# ABOUTME: Versoes fixadas de proposito -- "a ultima" nao e reproduzivel.
set -euo pipefail

# Versoes fixadas. Um ambiente que se comporta diferente conforme o dia em que
# foi criado nao atende ao requisito de provisionamento reproduzivel por codigo.
K3D_VERSION="v5.7.5"
KUBECTL_VERSION="v1.31.4"
HELM_VERSION="v3.16.3"
TERRAFORM_VERSION="1.10.3"
JUST_VERSION="1.38.0"
ARGOCD_VERSION="v2.13.2"
KUBECONFORM_VERSION="v0.6.7"
KUBE_LINTER_VERSION="v0.7.2"
SHELLCHECK_VERSION="v0.10.0"
ANSIBLE_LINT_VERSION="26.8.0"
HEY_VERSION="v0.1.5"
JQ_VERSION="jq-1.8.2"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"; [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ $EUID -ne 0 ]] && ! have sudo; then
    echo "preciso de root ou sudo para: $*" >&2; exit 1
  fi
}

# --- Deteccao de distro ---------------------------------------------------------
# So existem duas familias que importam aqui: quem tem `pacman` e quem tem `apt`.
# A grande maioria dos binarios abaixo vem direto do fornecedor (curl + release
# oficial), entao a distro so afeta quem precisa de um pacote do sistema:
# pipx (para o ansible) e o shellcheck/kube-linter quando ha pacote nativo.
OS_ID="unknown"
OS_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
fi

case " $OS_ID $OS_LIKE " in
  *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*) PKG_FAMILY="arch" ;;
  *" ubuntu "*|*" debian "*)                                PKG_FAMILY="debian" ;;
  *)
    PKG_FAMILY="unknown"
    log "distro '${OS_ID}' nao reconhecida (esperava Arch ou Ubuntu/Debian) -- prosseguindo, mas instalacao de pacotes do sistema (pipx) pode falhar"
    ;;
esac

pkg_install() {
  need_root "instalar pacote(s): $*"
  case "$PKG_FAMILY" in
    arch)   sudo pacman -Sy --noconfirm --needed "$@" ;;
    debian) sudo apt-get update -qq && sudo apt-get install -y "$@" ;;
    *)      echo "instale manualmente para sua distro: $*" >&2; exit 1 ;;
  esac
}

# --- Docker -------------------------------------------------------------------
# Nao instalado automaticamente feito o resto: nao e um binario estatico, e um
# daemon de sistema (systemd, cgroups, grupo unix) cuja instalacao diverge de
# verdade entre distros, e o `usermod -aG docker` so vale numa sessao NOVA --
# nenhum script consegue deixar isso pronto para uso no mesmo processo que o
# instalou. Preferi apontar o comando certo por distro a arriscar atropelar
# uma instalacao (Docker Desktop, Podman, DOCKER_HOST remoto) que a pessoa ja
# tenha configurado de proposito.
if ! have docker; then
  echo "Docker nao encontrado." >&2
  case "$PKG_FAMILY" in
    arch)
      echo "instale e habilite:" >&2
      echo "  sudo pacman -S --needed docker docker-compose" >&2
      echo "  sudo systemctl enable --now docker" >&2
      echo "  sudo usermod -aG docker \$USER" >&2
      ;;
    debian)
      echo "o pacote docker.io do apt costuma ficar desatualizado -- use o repositorio oficial:" >&2
      echo "  https://docs.docker.com/engine/install/ubuntu/" >&2
      echo "  sudo systemctl enable --now docker" >&2
      echo "  sudo usermod -aG docker \$USER" >&2
      ;;
    *)
      echo "instale o Docker Engine: https://docs.docker.com/engine/install/" >&2
      ;;
  esac
  echo "depois, faca logout/login (ou 'newgrp docker') -- o grupo so vale numa sessao nova." >&2
  exit 1
fi
docker info >/dev/null 2>&1 || { echo "o daemon do Docker nao responde -- 'sudo systemctl start docker'?" >&2; exit 1; }

# --- Binarios -------------------------------------------------------------------
install_kubectl() {
  have kubectl && [[ "$(kubectl version --client -o json | grep -o '"gitVersion": *"[^"]*' | head -1)" == *"$KUBECTL_VERSION"* ]] && return
  log "kubectl $KUBECTL_VERSION"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o "$BIN_DIR/kubectl"
  chmod +x "$BIN_DIR/kubectl"
}

install_k3d() {
  have k3d && [[ "$(k3d version | head -1)" == *"${K3D_VERSION#v}"* ]] && return
  log "k3d $K3D_VERSION"
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | TAG="$K3D_VERSION" K3D_INSTALL_DIR="$BIN_DIR" USE_SUDO=false bash
}

install_helm() {
  have helm && [[ "$(helm version --short)" == *"${HELM_VERSION}"* ]] && return
  log "helm $HELM_VERSION"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /tmp "linux-${ARCH}/helm"
  mv "/tmp/linux-${ARCH}/helm" "$BIN_DIR/helm"
}

install_terraform() {
  have terraform && [[ "$(terraform version -json | grep -o '"terraform_version": *"[^"]*')" == *"$TERRAFORM_VERSION"* ]] && return
  log "terraform $TERRAFORM_VERSION"
  curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" -o /tmp/tf.zip
  unzip -oq /tmp/tf.zip -d "$BIN_DIR" && rm /tmp/tf.zip
}

install_just() {
  have just && return
  log "just $JUST_VERSION"
  curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-$( [[ $ARCH == amd64 ]] && echo x86_64 || echo aarch64 )-unknown-linux-musl.tar.gz" \
    | tar -xz -C "$BIN_DIR" just
}

install_argocd() {
  have argocd && return
  log "argocd cli $ARGOCD_VERSION"
  curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}" -o "$BIN_DIR/argocd"
  chmod +x "$BIN_DIR/argocd"
}

install_kubeconform() {
  have kubeconform && return
  log "kubeconform $KUBECONFORM_VERSION"
  curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
    | tar -xz -C "$BIN_DIR" kubeconform
}

# jq e usado pelo Justfile (secrets-rotate), pelo scripts/e2e.sh e pelo fix de
# CoreDNS do k3d_cluster. Nem toda instalacao "minimal" de Ubuntu/Arch traz.
install_jq() {
  have jq && [[ "$(jq --version)" == *"${JQ_VERSION#jq-}"* ]] && return
  log "jq ${JQ_VERSION#jq-}"
  curl -fsSL "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-${ARCH}" -o "$BIN_DIR/jq"
  chmod +x "$BIN_DIR/jq"
}

# kube-linter e shellcheck nao tem versao pinada consistente nos repos oficiais
# de ambas as distros (o Arch as vezes empacota mais novo que o Ubuntu LTS) --
# baixar o binario da release fixa a versao igual nos dois sistemas, que e o
# ponto do requisito de reprodutibilidade.
install_kube_linter() {
  have kube-linter && [[ "$(kube-linter version 2>&1)" == *"${KUBE_LINTER_VERSION#v}"* ]] && return
  log "kube-linter $KUBE_LINTER_VERSION"
  curl -fsSL "https://github.com/stackrox/kube-linter/releases/download/${KUBE_LINTER_VERSION}/kube-linter-linux.tar.gz" \
    | tar -xz -C "$BIN_DIR" kube-linter
  chmod +x "$BIN_DIR/kube-linter"
}

install_shellcheck() {
  have shellcheck && [[ "$(shellcheck --version 2>&1)" == *"${SHELLCHECK_VERSION#v}"* ]] && return
  log "shellcheck $SHELLCHECK_VERSION"
  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.$( [[ $ARCH == amd64 ]] && echo x86_64 || echo aarch64 ).tar.xz" \
    | tar -xJ -C /tmp "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
  mv "/tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$BIN_DIR/shellcheck"
}

# ansible e ansible-lint vem de pipx, nao de pacote nativo: a versao do
# ansible-core empacotada varia demais entre Arch (rolling) e Ubuntu (LTS
# antigo), e pipx isola de qualquer outro python do sistema.
ensure_pipx() {
  have pipx && return
  log "pipx"
  case "$PKG_FAMILY" in
    arch)   pkg_install python-pipx ;;
    debian) pkg_install pipx ;;
    *)      echo "instale pipx manualmente: https://pipx.pypa.io/stable/installation/" >&2; exit 1 ;;
  esac
  pipx ensurepath >/dev/null 2>&1 || true
}

install_ansible() {
  have ansible-playbook && return
  log "ansible (pipx)"
  ensure_pipx
  pipx install --include-deps ansible
}

install_ansible_lint() {
  have ansible-lint && [[ "$(ansible-lint --version 2>&1 | head -1)" == *"$ANSIBLE_LINT_VERSION"* ]] && return
  log "ansible-lint $ANSIBLE_LINT_VERSION"
  ensure_pipx
  pipx install --force "ansible-lint==${ANSIBLE_LINT_VERSION}"
}

install_kubectl
install_k3d
install_helm
install_terraform
install_just
install_argocd
install_kubeconform
install_jq
install_kube_linter
install_shellcheck
install_ansible
install_ansible_lint

# --- inotify ------------------------------------------------------------------
# A CAUSA NUMERO 1 DE "FUNCIONA NA MINHA MAQUINA".
#
# O default do Ubuntu para fs.inotify.max_user_instances e 128 (o do Arch e
# 128 tambem, na pratica). Quatro nodes k3s mais Argo CD, Vault, ESO e CNPG --
# todos com watches de arquivo -- estouram isso de forma confiavel. O sintoma
# nao aponta para a causa: "too many open files" em componentes aleatorios,
# k3s reiniciando, pods presos em ContainerCreating. Persistido em
# /etc/sysctl.d para sobreviver ao reboot.
log "elevando os limites de inotify"
if [[ "$(sysctl -n fs.inotify.max_user_instances)" -lt 512 ]]; then
  need_root "ajustar sysctl"
  sudo tee /etc/sysctl.d/99-k3d.conf >/dev/null <<SYSCTL
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
SYSCTL
  sudo sysctl --system >/dev/null
fi

# --- Carga (opcional) ---------------------------------------------------------
# hey (rakyll/hey) nao publica binarios pre-compilados na release do GitHub --
# so tarball de fonte -- e o mirror S3 historicamente usado pela comunidade
# (hey-release.s3...) parou de responder (403). `go install` e a forma que
# sobrevive a esse tipo de link quebrado, porque nao depende de terceiro
# nenhum alem do proprio GitHub. Nao critico: so afeta `just demo-scale`.
if ! have hey; then
  if have go; then
    log "hey ${HEY_VERSION} (via go install)"
    GOBIN="$BIN_DIR" go install "github.com/rakyll/hey@${HEY_VERSION}" || \
      log "aviso: falha ao compilar hey -- 'just demo-scale' ficara indisponivel"
  else
    log "aviso: 'go' nao encontrado, pulando hey -- 'just demo-scale' ficara indisponivel"
  fi
fi

log "pronto."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo; echo "Adicione ao PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
