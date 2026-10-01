locals {
  # "<namespace>:<IdP group>" => policies. admin_groups and groups may name the same IdP group.
  groups = merge([
    for ns, v in var.namespaces : {
      for g in setunion(keys(v.groups), v.admin_groups) : "${ns}:${g}" => {
        namespace = ns
        name      = g
        policies = distinct(concat(
          lookup(v.groups, g, []),
          contains(v.admin_groups, g) ? ["namespace-admin"] : [],
        ))
      }
    }
  ]...)
}

resource "vault_identity_group" "this" {
  for_each = local.groups

  namespace = local.path[each.value.namespace]
  name      = each.value.name
  type      = "external"
  policies  = each.value.policies
}

resource "vault_identity_group_alias" "this" {
  for_each = local.groups

  namespace      = local.path[each.value.namespace]
  name           = each.value.name
  mount_accessor = vault_jwt_auth_backend.oidc[each.value.namespace].accessor
  canonical_id   = vault_identity_group.this[each.key].id
}
