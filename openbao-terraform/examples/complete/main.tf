terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }
}

# Reads VAULT_ADDR and VAULT_TOKEN for an identity in the root namespace.
provider "vault" {}

# Upstream OpenBao that signs the ACME intermediate. Only used when acme.ca.upstream is set.
provider "vault" {
  alias            = "upstream"
  address          = var.upstream_address
  token            = var.upstream_token
  skip_child_token = true # The token then needs only sign-intermediate on the upstream mount.
}

module "openbao" {
  source = "../../modules/openbao"

  providers = {
    vault          = vault
    vault.upstream = vault.upstream
  }

  namespaces          = var.namespaces
  oidc_defaults       = var.oidc_defaults
  oidc_client_secrets = var.oidc_client_secrets
  policies_dir        = "${path.root}/policies"
  acme                = var.acme
}

output "acme" {
  value = module.openbao.acme
}

output "approle_role_ids" {
  value = module.openbao.approle_role_ids
}
