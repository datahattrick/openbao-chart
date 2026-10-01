locals {
  approle = { for ns, v in var.namespaces : ns => v.approle if v.approle != null }

  approle_roles = merge([
    for ns, a in local.approle : { for role, r in a.roles : "${ns}:${role}" => merge(r, { namespace = ns, name = role }) }
  ]...)

  kubernetes = merge([
    for ns, v in var.namespaces : { for mount, k in v.kubernetes : "${ns}:${mount}" => merge(k, { namespace = ns, path = mount }) }
  ]...)

  kubernetes_roles = merge([
    for key, k in local.kubernetes : {
      for role, r in k.roles : "${key}/${role}" => merge(r, { namespace = k.namespace, mount = key, name = role })
    }
  ]...)

  # Namespace oidc fields override oidc_defaults where set.
  oidc = {
    for ns, v in var.namespaces : ns => merge(var.oidc_defaults, { for f, val in v.oidc : f => val if val != null })
    if v.oidc != null
  }
}

# AppRole

resource "vault_auth_backend" "approle" {
  for_each = local.approle

  namespace = local.path[each.key]
  type      = "approle"
  path      = each.value.path
}

resource "vault_approle_auth_backend_role" "this" {
  for_each = local.approle_roles

  namespace             = local.path[each.value.namespace]
  backend               = vault_auth_backend.approle[each.value.namespace].path
  role_name             = each.value.name
  token_policies        = each.value.token_policies
  token_ttl             = each.value.token_ttl
  token_max_ttl         = each.value.token_max_ttl
  token_bound_cidrs     = each.value.token_bound_cidrs
  secret_id_ttl         = each.value.secret_id_ttl
  secret_id_num_uses    = each.value.secret_id_num_uses
  secret_id_bound_cidrs = each.value.secret_id_bound_cidrs
}

# Kubernetes

resource "vault_auth_backend" "kubernetes" {
  for_each = local.kubernetes

  namespace = local.path[each.value.namespace]
  type      = "kubernetes"
  path      = each.value.path
}

resource "vault_kubernetes_auth_backend_config" "this" {
  for_each = local.kubernetes

  namespace            = local.path[each.value.namespace]
  backend              = vault_auth_backend.kubernetes[each.key].path
  kubernetes_host      = each.value.host
  kubernetes_ca_cert   = each.value.ca_cert
  issuer               = each.value.issuer
  token_reviewer_jwt   = each.value.token_reviewer_jwt
  disable_local_ca_jwt = each.value.disable_local_ca_jwt
}

resource "vault_kubernetes_auth_backend_role" "this" {
  for_each = local.kubernetes_roles

  namespace                        = local.path[each.value.namespace]
  backend                          = vault_auth_backend.kubernetes[each.value.mount].path
  role_name                        = each.value.name
  bound_service_account_names      = each.value.service_accounts
  bound_service_account_namespaces = each.value.namespaces
  audience                         = each.value.audience
  token_policies                   = each.value.token_policies
  token_ttl                        = each.value.token_ttl
  token_max_ttl                    = each.value.token_max_ttl
}

# OIDC. Authorisation comes from IdP groups (identity.tf), so the role grants no policies itself.

resource "vault_jwt_auth_backend" "oidc" {
  for_each = local.oidc

  namespace                     = local.path[each.key]
  type                          = "oidc"
  path                          = each.value.path
  oidc_discovery_url            = each.value.discovery_url
  oidc_client_id                = each.value.client_id
  oidc_client_secret_wo         = lookup(var.oidc_client_secrets, each.key, null)
  oidc_client_secret_wo_version = each.value.client_secret_version
  default_role                  = "default"
  namespace_in_state            = true

  tune {
    listing_visibility = each.value.listed_in_ui ? "unauth" : "hidden"
  }

  lifecycle {
    precondition {
      condition     = each.value.discovery_url != null && each.value.ui_url != null
      error_message = "${each.key}: oidc needs discovery_url and ui_url, in the namespace or in oidc_defaults."
    }
    precondition {
      condition     = contains(keys(var.oidc_client_secrets), each.key)
      error_message = "${each.key}: oidc needs a client secret in oidc_client_secrets[\"${each.key}\"]."
    }
  }
}

resource "vault_jwt_auth_backend_role" "oidc" {
  for_each = local.oidc

  namespace       = local.path[each.key]
  backend         = vault_jwt_auth_backend.oidc[each.key].path
  role_name       = "default"
  role_type       = "oidc"
  user_claim      = each.value.user_claim
  groups_claim    = each.value.groups_claim
  oidc_scopes     = each.value.scopes
  bound_audiences = each.value.bound_audiences
  bound_claims    = each.value.bound_claims
  token_ttl       = each.value.token_ttl
  token_max_ttl   = each.value.token_ttl

  allowed_redirect_uris = [
    "${trimsuffix(each.value.ui_url, "/")}/ui/vault/auth/${each.value.path}/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
}
