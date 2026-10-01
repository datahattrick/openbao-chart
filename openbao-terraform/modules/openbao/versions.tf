terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = ">= 5.0, < 6.0"

      # Upstream OpenBao that signs the ACME intermediate. Pass vault.upstream = vault when not used.
      configuration_aliases = [vault.upstream]
    }
  }
}
