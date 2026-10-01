variable "namespaces" {
  description = <<-EOT
    Namespaces keyed by full path, e.g. "orga/areab/teamc". Every parent must also be listed.
    type is one of:
      container: organisational only, no logins.
      branch:    delegated admins log in via OIDC and own everything below.
      leaf:      a team's namespace, logged into via OIDC. The team owns it, including any children
                 they create; OpenTofu places no namespaces under it.
  EOT
  type = map(object({
    type            = string
    custom_metadata = optional(map(string), {})

    # OIDC login, required for branch and leaf. Unset fields come from oidc_defaults.
    oidc = optional(object({
      client_id             = string
      client_secret_version = optional(number, 1)
      discovery_url         = optional(string)
      ui_url                = optional(string)
      path                  = optional(string)
      user_claim            = optional(string)
      groups_claim          = optional(string)
      scopes                = optional(list(string))
      bound_audiences       = optional(list(string))
      bound_claims          = optional(map(string))
      token_ttl             = optional(number)
      listed_in_ui          = optional(bool)
    }))

    # IdP groups given full control of the namespace and everything below it. Required for branch.
    admin_groups = optional(list(string), [])

    # Other IdP groups, as IdP group name => policy names.
    groups = optional(map(list(string)), {})

    # Inline ACL policies, as name => HCL. Also read from policies_dir.
    policies = optional(map(string), {})

    # Leaf only from here on.

    kv = optional(map(object({
      description          = optional(string)
      max_versions         = optional(number, 10)
      cas_required         = optional(bool, false)
      delete_version_after = optional(number, 0)
    })), {})

    secrets_engines = optional(map(object({
      type                      = string
      description               = optional(string)
      options                   = optional(map(string))
      default_lease_ttl_seconds = optional(number)
      max_lease_ttl_seconds     = optional(number)
    })), {})

    approle = optional(object({
      path = optional(string, "approle")
      roles = optional(map(object({
        token_policies        = list(string)
        token_ttl             = optional(number, 3600)
        token_max_ttl         = optional(number, 14400)
        token_bound_cidrs     = optional(list(string))
        secret_id_ttl         = optional(number, 0)
        secret_id_num_uses    = optional(number, 0)
        secret_id_bound_cidrs = optional(list(string))
      })), {})
    }))

    kubernetes = optional(map(object({
      host               = string
      ca_cert            = optional(string)
      issuer             = optional(string)
      token_reviewer_jwt = optional(string)
      # Set when OpenBao runs outside this cluster; otherwise it reads the pod's own CA and token.
      disable_local_ca_jwt = optional(bool, false)
      roles = optional(map(object({
        service_accounts = list(string)
        namespaces       = list(string)
        token_policies   = list(string)
        audience         = optional(string)
        token_ttl        = optional(number, 3600)
        token_max_ttl    = optional(number, 14400)
      })), {})
    })), {})
  }))

  validation {
    condition     = alltrue([for k in keys(var.namespaces) : can(regex("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", k))])
    error_message = "Namespace keys are paths like orga/areab/teamc, with no leading or trailing slash."
  }

  validation {
    condition     = alltrue([for k in keys(var.namespaces) : length(split("/", k)) <= 6])
    error_message = "Namespaces can be at most 6 levels deep."
  }

  validation {
    condition     = alltrue([for v in values(var.namespaces) : contains(["container", "branch", "leaf"], v.type)])
    error_message = "type must be container, branch or leaf."
  }

  validation {
    condition = alltrue([
      for k in keys(var.namespaces) : length(split("/", k)) == 1 || contains(keys(var.namespaces), join("/", slice(split("/", k), 0, length(split("/", k)) - 1)))
    ])
    error_message = "Missing parent namespaces: ${join(", ", [for k in keys(var.namespaces) : k if length(split("/", k)) > 1 && !contains(keys(var.namespaces), join("/", slice(split("/", k), 0, length(split("/", k)) - 1)))])}."
  }

  validation {
    condition = alltrue([
      for k in keys(var.namespaces) : length(split("/", k)) == 1 || try(var.namespaces[join("/", slice(split("/", k), 0, length(split("/", k)) - 1))].type != "leaf", true)
    ])
    error_message = "Namespaces under a leaf belong to its team, not to OpenTofu: ${join(", ", [for k in keys(var.namespaces) : k if length(split("/", k)) > 1 && try(var.namespaces[join("/", slice(split("/", k), 0, length(split("/", k)) - 1))].type == "leaf", false)])}."
  }

  validation {
    condition = alltrue([
      for v in values(var.namespaces) : v.type != "container" || (v.oidc == null && length(v.admin_groups) + length(v.groups) + length(v.policies) == 0)
    ])
    error_message = "A container has no logins, so it takes no oidc, admin_groups, groups or policies: ${join(", ", [for k, v in var.namespaces : k if v.type == "container" && (v.oidc != null || length(v.admin_groups) + length(v.groups) + length(v.policies) > 0)])}."
  }

  validation {
    condition     = alltrue([for v in values(var.namespaces) : v.type == "container" || v.oidc != null])
    error_message = "Branch and leaf namespaces require oidc: ${join(", ", [for k, v in var.namespaces : k if v.type != "container" && v.oidc == null])}."
  }

  validation {
    condition     = alltrue([for v in values(var.namespaces) : v.type != "branch" || length(v.admin_groups) > 0])
    error_message = "Branch namespaces require admin_groups: ${join(", ", [for k, v in var.namespaces : k if v.type == "branch" && length(v.admin_groups) == 0])}."
  }

  validation {
    condition = alltrue([
      for v in values(var.namespaces) : v.type == "leaf" || length(v.kv) + length(v.secrets_engines) + length(v.kubernetes) + (v.approle == null ? 0 : 1) == 0
    ])
    error_message = "kv, secrets_engines, approle and kubernetes are only for leaf namespaces: ${join(", ", [for k, v in var.namespaces : k if v.type != "leaf" && length(v.kv) + length(v.secrets_engines) + length(v.kubernetes) + (v.approle == null ? 0 : 1) > 0])}."
  }

  validation {
    condition     = alltrue([for v in values(var.namespaces) : !contains(keys(v.policies), "namespace-admin")])
    error_message = "The policy name namespace-admin is reserved for the module."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.namespaces) : [for c in values(v.kubernetes) : !c.disable_local_ca_jwt || c.ca_cert != null]
    ]))
    error_message = "kubernetes: disable_local_ca_jwt requires ca_cert."
  }
}

variable "oidc_defaults" {
  description = "OIDC settings shared by every namespace with a login. A namespace's oidc overrides them field by field."
  type = object({
    discovery_url   = optional(string)
    ui_url          = optional(string)
    path            = optional(string, "oidc")
    user_claim      = optional(string, "email")
    groups_claim    = optional(string, "groups")
    scopes          = optional(list(string), ["openid", "email", "profile"])
    bound_audiences = optional(list(string))
    bound_claims    = optional(map(string))
    token_ttl       = optional(number, 28800)
    listed_in_ui    = optional(bool, true)
  })
  default = {}
}

variable "oidc_client_secrets" {
  description = "OIDC client secret per namespace, keyed by namespace path. Write-only: never stored in state."
  type        = map(string)
  default     = {}
  ephemeral   = true
}

variable "policies_dir" {
  description = "Directory of policy files laid out as <dir>/<namespace path>/<policy name>.hcl. null disables it."
  type        = string
  default     = null
}

variable "acme" {
  description = "ACME namespace. null leaves it out. See modules/acme/variables.tf for every field."
  type = object({
    namespace                   = optional(string, "acme")
    mount_path                  = optional(string, "pki")
    cluster_url                 = string
    allowed_domains             = list(string)
    allow_subdomains            = optional(bool, true)
    allow_bare_domains          = optional(bool, false)
    allow_wildcard_certificates = optional(bool, false)
    allow_ip_sans               = optional(bool, false)
    ttl                         = optional(number, 2592000)
    max_ttl                     = optional(number, 7776000)
    eab_policy                  = optional(string, "not-required")
    dns_resolver                = optional(string)
    ca = optional(object({
      common_name      = optional(string)
      organization     = optional(string)
      key_type         = optional(string)
      key_bits         = optional(number)
      self_signed_ttl  = optional(string)
      intermediate     = optional(bool)
      certificate      = optional(string)
      certificate_file = optional(string)
      upstream = optional(object({
        mount_path       = string
        namespace        = optional(string)
        issuer_ref       = optional(string)
        ttl              = optional(string)
        name_constraints = optional(bool)
        renew            = optional(number)
      }))
    }), {})
  })
  default = null

  validation {
    condition     = var.acme == null || !contains(keys(var.namespaces), try(var.acme.namespace, ""))
    error_message = "The acme namespace is managed by the acme input. Remove it from namespaces."
  }
}
