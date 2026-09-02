# ABOUTME: Instala o Vault. O bootstrap (init/unseal) NAO acontece aqui -- e no Ansible.
# ABOUTME: Ler o comentario sobre `wait` antes de mexer neste arquivo.
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.vault_chart_version
  namespace  = kubernetes_namespace.this["vault"].metadata[0].name

  # ---------------------------------------------------------------------------
  # wait = false NAO E UM DETALHE DE PERFORMANCE. E o que impede um deadlock.
  #
  # O readinessProbe do chart do Vault executa `vault status`, que retorna:
  #   exit 0 -> destrancado
  #   exit 1 -> erro
  #   exit 2 -> SELADO
  #
  # Um Vault recem-instalado nasce selado e nao inicializado. Ele so e destrancado
  # depois de `vault operator init`, que e o passo seguinte, feito pelo Ansible.
  # Ou seja: o Pod NUNCA fica Ready antes do bootstrap.
  #
  # Com wait = true, o terraform apply fica bloqueado esperando um Ready que
  # depende de um passo que so roda depois do apply terminar. Trava ate o timeout,
  # falha, e o `just up` morre sem nenhuma mensagem que aponte para a causa.
  #
  # Pelo mesmo motivo o Vault nao pode ser uma Application do Argo CD: o
  # StatefulSet ficaria 0/1, a Application ficaria Progressing para sempre e a
  # sync wave nunca avancaria.
  # ---------------------------------------------------------------------------
  wait    = false
  timeout = 600

  values = [yamlencode({
    global = {
      tlsDisable = true # TLS interno dispensavel: o cluster e efemero e local
    }

    injector = {
      # Nao usamos o sidecar injector: quem materializa Secrets aqui e o External
      # Secrets Operator. Duas ferramentas fazendo a mesma coisa seria confusao
      # na hora de explicar.
      enabled = false
    }

    server = {
      # Standalone com storage em arquivo. Raft (HA) exigiria 3 replicas, cada uma
      # precisando de unseal, num cluster que roda num host so. Complexidade sem
      # disponibilidade adicional.
      standalone = {
        enabled = true
        config  = <<-HCL
          ui = true

          listener "tcp" {
            tls_disable = 1
            address     = "[::]:8200"
            cluster_address = "[::]:8201"
          }

          storage "file" {
            path = "/vault/data"
          }
        HCL
      }

      ha = { enabled = false }

      dataStorage = {
        enabled      = true
        size         = "1Gi"
        storageClass = "local-path"
      }

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }

      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        annotations = {
          "cert-manager.io/cluster-issuer" = "todolist-ca"
        }
        hosts = [{ host = "vault.${var.base_domain}", paths = [] }]
        tls   = [{ secretName = "vault-tls", hosts = ["vault.${var.base_domain}"] }]
      }
    }

    ui = {
      enabled = true
      # ClusterIP: o acesso externo passa pelo Ingress, nao por NodePort.
      serviceType = "ClusterIP"
    }
  })]

  depends_on = [kubernetes_namespace.this]
}

# ---------------------------------------------------------------------------
# Sem isto, o auth/kubernetes do Vault falha com "permission denied" na hora do
# LOGIN (nao na hora de configurar) -- porque o proprio Vault precisa poder
# criar um TokenReview contra o API server para validar o token que o ESO
# apresenta. O chart do Vault NAO cria este binding sozinho; e um passo manual
# documentado pela HashiCorp e omitido com frequencia, e o sintoma e identico
# ao de audience errada ou cofre selado -- a mesma "permission denied" que o
# playbook ja trata como o maior risco da entrega.
# ---------------------------------------------------------------------------
resource "kubernetes_cluster_role_binding" "vault_auth_delegator" {
  metadata {
    name = "vault-server-auth-delegator"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "vault"
    namespace = kubernetes_namespace.this["vault"].metadata[0].name
  }

  depends_on = [helm_release.vault]
}
