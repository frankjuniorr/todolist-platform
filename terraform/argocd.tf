# ABOUTME: Instala o Argo CD -- a unica peca instalada imperativamente de proposito.
# ABOUTME: A partir daqui, todo o resto do cluster e declarado em Git.
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.this["argocd"].metadata[0].name

  # Aqui `wait = true` e correto e desejado: o Ansible so pode aplicar o
  # App-of-Apps depois que o servidor da API do Argo CD estiver de pe.
  wait          = true
  timeout       = 600
  atomic        = true
  wait_for_jobs = true

  values = [yamlencode({
    configs = {
      params = {
        # O Traefik termina o TLS na borda e fala HTTP com o Pod. Sem isto, o
        # argocd-server tambem tenta redirecionar para HTTPS e o navegador entra
        # em loop: ERR_TOO_MANY_REDIRECTS.
        "server.insecure" = true
      }
      cm = {
        # Health check customizado para o CRD do External Secrets.
        #
        # Sem isto, o Argo CD trata um ExternalSecret como Healthy assim que o
        # objeto existe -- e a sync wave avanca antes de o Secret ter sido escrito
        # no cluster. O Deployment sobe apontando para um Secret inexistente e
        # fica em CreateContainerConfigError.
        #
        # A wave sozinha nao garante ordem: ela so avanca quando a wave anterior
        # esta Healthy, entao a definicao de "Healthy" e o mecanismo real.
        "resource.customizations.health.external-secrets.io_ExternalSecret" = <<-LUA
          hs = {}
          if obj.status ~= nil and obj.status.conditions ~= nil then
            for i, condition in ipairs(obj.status.conditions) do
              if condition.type == "Ready" and condition.status == "True" then
                hs.status = "Healthy"
                hs.message = condition.message
                return hs
              end
              if condition.type == "Ready" and condition.status == "False" then
                hs.status = "Degraded"
                hs.message = condition.message
                return hs
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "aguardando sincronizacao com o Vault"
          return hs
        LUA
      }
    }

    global = {
      # 4 nos no k3d competem por CPU do mesmo host. Requests baixos evitam Pods
      # em Pending por falta de recurso alocavel.
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
      }
    }

    server = {
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        hostname         = "argocd.${var.base_domain}"
        annotations = {
          "cert-manager.io/cluster-issuer" = "todolist-ca"
        }
        tls = true
        extraTls = [{
          hosts      = ["argocd.${var.base_domain}"]
          secretName = "argocd-server-tls"
        }]
      }
    }

    # Nao ha Redis HA nem alta disponibilidade real num cluster de um host so;
    # replicas extras aqui gastariam CPU sem entregar disponibilidade.
    redis-ha       = { enabled = false }
    controller     = { replicas = 1 }
    repoServer     = { replicas = 1 }
    applicationSet = { replicas = 1 }

    # Dex nao e usado: a autenticacao e o usuario admin local.
    dex = { enabled = false }
  })]

  depends_on = [kubernetes_namespace.this]
}

# A senha inicial do admin fica num Secret gerado pelo proprio Argo CD.
data "kubernetes_secret" "argocd_admin" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = kubernetes_namespace.this["argocd"].metadata[0].name
  }
  depends_on = [helm_release.argocd]
}
