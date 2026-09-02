# ABOUTME: Providers e versoes. Sem backend remoto: o state e local e descartavel,
# ABOUTME: porque o cluster inteiro e recriado por `just down && just up`.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      # alekc/kubectl, e nao gavinbunney/kubectl: o original esta sem manutencao
      # desde 2023 e nao acompanhou o provider protocol v6.
      #
      # Por que nao o recurso nativo kubernetes_manifest: ele consulta o schema do
      # CRD durante o `plan`. Para um CR cujo CRD ainda nao existe no cluster --
      # que e exatamente o nosso caso no primeiro apply -- o plan falha antes de
      # qualquer coisa ser criada. Nao ha ordem de dependencia que resolva.
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}
