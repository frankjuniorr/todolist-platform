variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Caminho do kubeconfig gerado pelo k3d."
}

variable "kube_context" {
  type        = string
  default     = "k3d-todolist"
  description = "Contexto do cluster k3d."
}

variable "argocd_chart_version" {
  type        = string
  default     = "7.7.11"
  description = "Versao do chart argo-cd (nao a versao do Argo CD)."
}

variable "vault_chart_version" {
  type        = string
  default     = "0.29.1"
  description = "Versao do chart hashicorp/vault."
}

variable "gitops_repo_url" {
  type        = string
  description = "URL publica do repositorio de plataforma que o Argo CD observa."
}

variable "gitops_repo_revision" {
  type        = string
  default     = "main"
  description = "Branch ou tag observada pelo Argo CD."
}

variable "base_domain" {
  type        = string
  default     = "localhost"
  description = "Dominio base dos Ingress. `localhost` resolve para 127.0.0.1 nativamente."
}
