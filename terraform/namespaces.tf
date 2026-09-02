# ABOUTME: Namespaces criados pelo Terraform.
# ABOUTME: Apenas os que precisam existir ANTES do Argo CD assumir o controle.
locals {
  # O namespace da aplicacao NAO esta aqui de proposito: quem o cria e a
  # Application do Argo CD, com CreateNamespace=true. Namespace gerenciado por
  # duas ferramentas e a origem classica de OutOfSync eterno.
  namespaces = {
    argocd = {}
    vault  = {}
  }
}

resource "kubernetes_namespace" "this" {
  for_each = local.namespaces

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # Pod Security Admission: o Vault precisa de IPC_LOCK para impedir que a
      # memoria com as chaves va para swap, o que exige o nivel `privileged`.
      "pod-security.kubernetes.io/enforce" = each.key == "vault" ? "privileged" : "baseline"
    }
  }
}
