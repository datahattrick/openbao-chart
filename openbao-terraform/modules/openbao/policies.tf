locals {
  file_policies = var.policies_dir == null ? {} : merge([
    for ns in keys(var.namespaces) : {
      for f in fileset("${var.policies_dir}/${ns}", "*.hcl") : "${ns}:${trimsuffix(f, ".hcl")}" => {
        namespace = ns
        name      = trimsuffix(f, ".hcl")
        policy    = file("${var.policies_dir}/${ns}/${f}")
      }
    }
  ]...)

  inline_policies = merge([
    for ns, v in var.namespaces : {
      for name, policy in v.policies : "${ns}:${name}" => { namespace = ns, name = name, policy = policy }
    }
  ]...)

  # Inline wins over a file of the same name.
  policies = merge(local.file_policies, local.inline_policies)
}

resource "vault_policy" "this" {
  for_each = local.policies

  namespace = local.path[each.value.namespace]
  name      = each.value.name
  policy    = each.value.policy

  lifecycle {
    precondition {
      condition     = var.namespaces[each.value.namespace].type != "container"
      error_message = "${each.value.namespace}: a container has no logins, so it takes no policies."
    }
    precondition {
      condition     = each.value.name != "namespace-admin"
      error_message = "${each.value.namespace}: the policy name namespace-admin is reserved for the module."
    }
  }
}

resource "vault_policy" "admin" {
  for_each = { for ns, v in var.namespaces : ns => v if length(v.admin_groups) > 0 }

  namespace = local.path[each.key]
  name      = "namespace-admin"
  policy    = file("${path.module}/templates/namespace-admin.hcl")
}
