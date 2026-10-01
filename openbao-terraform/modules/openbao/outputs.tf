output "namespaces" {
  description = "Namespace IDs keyed by path."
  value = merge(
    { for k, r in vault_namespace.depth_1 : k => r.namespace_id },
    { for k, r in vault_namespace.depth_2 : k => r.namespace_id },
    { for k, r in vault_namespace.depth_3 : k => r.namespace_id },
    { for k, r in vault_namespace.depth_4 : k => r.namespace_id },
    { for k, r in vault_namespace.depth_5 : k => r.namespace_id },
    { for k, r in vault_namespace.depth_6 : k => r.namespace_id },
  )
}

output "approle_role_ids" {
  description = "AppRole role IDs keyed by \"<namespace>:<role>\"."
  value       = { for k, r in vault_approle_auth_backend_role.this : k => r.role_id }
}

output "auth_accessors" {
  description = "Auth method accessors keyed by \"<namespace>:<mount path>\"."
  value = merge(
    { for k, b in vault_auth_backend.approle : "${k}:${b.path}" => b.accessor },
    { for k, b in vault_auth_backend.kubernetes : k => b.accessor },
    { for k, b in vault_jwt_auth_backend.oidc : "${k}:${b.path}" => b.accessor },
  )
}

output "acme" {
  description = "ACME directory URL, pending CSR and CA chain. null when acme is not set."
  value = var.acme == null ? null : {
    directory_url = module.acme[0].directory_url
    csr           = module.acme[0].csr
    issuer_id     = module.acme[0].issuer_id
    ca_chain      = module.acme[0].ca_chain
  }
}
