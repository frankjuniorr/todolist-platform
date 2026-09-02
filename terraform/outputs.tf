output "argocd_admin_password" {
  value       = data.kubernetes_secret.argocd_admin.data["password"]
  sensitive   = true
  description = "Senha inicial do usuario admin do Argo CD."
}

output "urls" {
  value = {
    aplicacao = "https://todolist.${var.base_domain}"
    argocd    = "https://argocd.${var.base_domain}"
    vault     = "https://vault.${var.base_domain}"
  }
}
