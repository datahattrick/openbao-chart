locals {
  kv = merge([
    for ns, v in var.namespaces : { for mount, m in v.kv : "${ns}:${mount}" => merge(m, { namespace = ns, path = mount }) }
  ]...)

  secrets_engines = merge([
    for ns, v in var.namespaces : { for mount, m in v.secrets_engines : "${ns}:${mount}" => merge(m, { namespace = ns, path = mount }) }
  ]...)
}

resource "vault_mount" "kv" {
  for_each = local.kv

  namespace   = local.path[each.value.namespace]
  path        = each.value.path
  type        = "kv"
  description = each.value.description
  options     = { version = "2" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_kv_secret_backend_v2" "kv" {
  for_each = local.kv

  namespace            = local.path[each.value.namespace]
  mount                = vault_mount.kv[each.key].path
  max_versions         = each.value.max_versions
  cas_required         = each.value.cas_required
  delete_version_after = each.value.delete_version_after
}

resource "vault_mount" "engine" {
  for_each = local.secrets_engines

  namespace                 = local.path[each.value.namespace]
  path                      = each.value.path
  type                      = each.value.type
  description               = each.value.description
  options                   = each.value.options
  default_lease_ttl_seconds = each.value.default_lease_ttl_seconds
  max_lease_ttl_seconds     = each.value.max_lease_ttl_seconds

  lifecycle {
    prevent_destroy = true
  }
}
