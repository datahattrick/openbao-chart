locals {
  segments = { for k in keys(var.namespaces) : k => split("/", k) }
  name     = { for k, s in local.segments : k => s[length(s) - 1] }
  parent   = { for k, s in local.segments : k => length(s) == 1 ? null : join("/", slice(s, 0, length(s) - 1)) }
  at_depth = { for d in range(1, 7) : d => { for k, s in local.segments : k => var.namespaces[k] if length(s) == d } }

  metadata = { for k, v in var.namespaces : k => merge(v.custom_metadata, { namespace_type = v.type }) }

  # Fully qualified path of every namespace. Referencing this makes a resource wait for all namespaces.
  path = merge(
    { for k, r in vault_namespace.depth_1 : k => r.path_fq },
    { for k, r in vault_namespace.depth_2 : k => r.path_fq },
    { for k, r in vault_namespace.depth_3 : k => r.path_fq },
    { for k, r in vault_namespace.depth_4 : k => r.path_fq },
    { for k, r in vault_namespace.depth_5 : k => r.path_fq },
    { for k, r in vault_namespace.depth_6 : k => r.path_fq },
  )
}

# One resource per depth, so each namespace is created after its parent.
# Deleting a namespace deletes every secret in it, so OpenTofu refuses to.

resource "vault_namespace" "depth_1" {
  for_each = local.at_depth[1]

  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_namespace" "depth_2" {
  for_each = local.at_depth[2]

  namespace       = vault_namespace.depth_1[local.parent[each.key]].path_fq
  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_namespace" "depth_3" {
  for_each = local.at_depth[3]

  namespace       = vault_namespace.depth_2[local.parent[each.key]].path_fq
  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_namespace" "depth_4" {
  for_each = local.at_depth[4]

  namespace       = vault_namespace.depth_3[local.parent[each.key]].path_fq
  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_namespace" "depth_5" {
  for_each = local.at_depth[5]

  namespace       = vault_namespace.depth_4[local.parent[each.key]].path_fq
  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_namespace" "depth_6" {
  for_each = local.at_depth[6]

  namespace       = vault_namespace.depth_5[local.parent[each.key]].path_fq
  path            = local.name[each.key]
  custom_metadata = local.metadata[each.key]

  lifecycle {
    prevent_destroy = true
  }
}
