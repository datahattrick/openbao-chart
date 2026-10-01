locals {
  base_url = "${trimsuffix(var.cluster_url, "/")}/v1/${var.namespace}/${var.mount_path}"

  upstream     = var.ca.upstream != null
  intermediate = var.ca.intermediate || local.upstream

  # Known at plan time, so it can drive count.
  use_signed = local.upstream || (var.ca.intermediate && (var.ca.certificate != null || var.ca.certificate_file != null))

  certificate = (
    local.upstream ? join("\n", concat(
      [vault_pki_secret_backend_root_sign_intermediate.this[0].certificate],
      vault_pki_secret_backend_root_sign_intermediate.this[0].ca_chain,
    ))
    : var.ca.certificate_file != null ? file(var.ca.certificate_file)
    : var.ca.certificate
  )

  # A chain imports one issuer per certificate it does not already have.
  # Ours is the one just imported that holds the CSR's key.
  issuer_id = local.use_signed ? one([
    for id, i in jsondecode(data.vault_pki_secret_backend_issuers.this[0].key_info_json) : id
    if contains(vault_pki_secret_backend_intermediate_set_signed.this[0].imported_issuers, id)
    && try(i.key_id, "") == vault_pki_secret_backend_intermediate_cert_request.this[0].key_id
  ]) : vault_pki_secret_backend_root_cert.self_signed[0].issuer_id
}

resource "vault_namespace" "this" {
  path            = var.namespace
  custom_metadata = { namespace_type = "acme" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_mount" "pki" {
  namespace             = vault_namespace.this.path_fq
  path                  = var.mount_path
  type                  = "pki"
  description           = "ACME certificate issuance"
  max_lease_ttl_seconds = 315360000 # 10 years, the ceiling for the CA itself

  # Required by the ACME protocol.
  allowed_response_headers    = ["Last-Modified", "Location", "Replay-Nonce", "Link"]
  passthrough_request_headers = ["If-Modified-Since"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_pki_secret_backend_config_cluster" "this" {
  namespace = vault_namespace.this.path_fq
  backend   = vault_mount.pki.path
  path      = local.base_url
  aia_path  = local.base_url
}

resource "vault_pki_secret_backend_config_urls" "this" {
  namespace               = vault_namespace.this.path_fq
  backend                 = vault_mount.pki.path
  enable_templating       = true
  issuing_certificates    = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/der"]
  crl_distribution_points = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der"]
  ocsp_servers            = ["{{cluster_path}}/ocsp"]

  depends_on = [vault_pki_secret_backend_config_cluster.this]
}

# Self-signed CA, until a signed intermediate is set.

resource "vault_pki_secret_backend_root_cert" "self_signed" {
  count = local.use_signed ? 0 : 1

  namespace    = vault_namespace.this.path_fq
  backend      = vault_mount.pki.path
  type         = "internal"
  common_name  = var.ca.common_name
  organization = var.ca.organization
  key_type     = var.ca.key_type
  key_bits     = var.ca.key_bits
  ttl          = var.ca.self_signed_ttl
  issuer_name  = "self-signed"

  # Keep issuing from it until the signed intermediate is the default issuer.
  lifecycle {
    create_before_destroy = true
  }
}

# Intermediate signed by your CA. The key is generated in OpenBao and never leaves it.

resource "vault_pki_secret_backend_intermediate_cert_request" "this" {
  count = local.intermediate ? 1 : 0

  namespace    = vault_namespace.this.path_fq
  backend      = vault_mount.pki.path
  type         = "internal"
  common_name  = var.ca.common_name
  organization = var.ca.organization
  key_type     = var.ca.key_type
  key_bits     = var.ca.key_bits
  key_name     = "intermediate"

  lifecycle {
    prevent_destroy = true
  }
}

# Signed by an upstream OpenBao, through the vault.upstream provider.
# The provider updates most fields in place without signing again, so any change replaces it.
resource "terraform_data" "upstream_signing" {
  count = local.upstream ? 1 : 0
  input = merge(var.ca.upstream, { allowed_domains = var.allowed_domains, common_name = var.ca.common_name })
}

resource "vault_pki_secret_backend_root_sign_intermediate" "this" {
  count    = local.upstream ? 1 : 0
  provider = vault.upstream

  namespace             = var.ca.upstream.namespace
  backend               = var.ca.upstream.mount_path
  issuer_ref            = var.ca.upstream.issuer_ref
  csr                   = vault_pki_secret_backend_intermediate_cert_request.this[0].csr
  common_name           = var.ca.common_name
  organization          = var.ca.organization
  ttl                   = var.ca.upstream.ttl
  max_path_length       = 0
  permitted_dns_domains = var.ca.upstream.name_constraints ? var.allowed_domains : null

  lifecycle {
    replace_triggered_by = [terraform_data.upstream_signing]
  }
}

resource "vault_pki_secret_backend_intermediate_set_signed" "this" {
  count = local.use_signed ? 1 : 0

  namespace   = vault_namespace.this.path_fq
  backend     = vault_mount.pki.path
  certificate = local.certificate
}

data "vault_pki_secret_backend_issuers" "this" {
  count = local.use_signed ? 1 : 0

  namespace = vault_namespace.this.path_fq
  backend   = vault_mount.pki.path

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.this]
}

resource "vault_pki_secret_backend_config_issuers" "this" {
  namespace = vault_namespace.this.path_fq
  backend   = vault_mount.pki.path
  default   = local.issuer_id

  lifecycle {
    precondition {
      condition     = local.issuer_id != null
      error_message = "The signed certificate does not match the key of the CSR OpenBao generated."
    }
  }
}

data "vault_pki_secret_backend_issuer" "default" {
  namespace  = vault_namespace.this.path_fq
  backend    = vault_mount.pki.path
  issuer_ref = vault_pki_secret_backend_config_issuers.this.default
}

# ACME

resource "vault_pki_secret_backend_role" "acme" {
  namespace                   = vault_namespace.this.path_fq
  backend                     = vault_mount.pki.path
  name                        = "acme"
  issuer_ref                  = "default"
  allowed_domains             = var.allowed_domains
  allow_subdomains            = var.allow_subdomains
  allow_bare_domains          = var.allow_bare_domains
  allow_wildcard_certificates = var.allow_wildcard_certificates
  allow_ip_sans               = var.allow_ip_sans
  allow_localhost             = false
  key_type                    = "any"
  ttl                         = var.ttl
  max_ttl                     = var.max_ttl
}

resource "vault_pki_secret_backend_config_acme" "this" {
  namespace                = vault_namespace.this.path_fq
  backend                  = vault_mount.pki.path
  enabled                  = true
  allowed_issuers          = [vault_pki_secret_backend_config_issuers.this.default]
  allowed_roles            = [vault_pki_secret_backend_role.acme.name]
  default_directory_policy = "role:${vault_pki_secret_backend_role.acme.name}"
  eab_policy               = var.eab_policy
  dns_resolver             = var.dns_resolver

  depends_on = [
    vault_pki_secret_backend_config_cluster.this,
    vault_pki_secret_backend_config_issuers.this,
  ]
}

resource "vault_pki_secret_backend_config_auto_tidy" "this" {
  namespace          = vault_namespace.this.path_fq
  backend            = vault_mount.pki.path
  enabled            = true
  interval_duration  = "12h"
  tidy_cert_store    = true
  tidy_revoked_certs = true
  tidy_acme          = true
}
