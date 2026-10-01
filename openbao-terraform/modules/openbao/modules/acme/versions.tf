terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = ">= 5.0, < 6.0"

      # Signs the intermediate when ca.upstream is set. Pass vault.upstream = vault when it is not.
      configuration_aliases = [vault.upstream]
    }
  }
}
