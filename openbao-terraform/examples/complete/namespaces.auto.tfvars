oidc_defaults = {
  discovery_url = "https://login.example.com/realms/corp"
  ui_url        = "https://openbao.example.com"
}

namespaces = {
  "orga" = {
    type = "container"
  }

  "orga/areab" = {
    type = "container"
  }

  "orga/aread" = {
    type         = "branch"
    oidc         = { client_id = "openbao-orga-aread" }
    admin_groups = ["aread-admins"]
  }

  # Policies for this namespace are in policies/orga/areab/teamc/.
  "orga/areab/teamc" = {
    type            = "leaf"
    custom_metadata = { cost-centre = "cc-1234" }
    oidc            = { client_id = "openbao-orga-areab-teamc" }

    admin_groups = ["teamc-admins"]
    groups = {
      teamc-developers = ["app-read"]
    }

    kv = {
      secret = { description = "Application secrets", max_versions = 20 }
    }

    secrets_engines = {
      transit = { type = "transit", description = "Encryption as a service" }
    }

    approle = {
      roles = {
        ci = { token_policies = ["ci-read"], secret_id_ttl = 86400 }
      }
    }

    kubernetes = {
      k8s-prod-eu = {
        host                 = "https://k8s-prod-eu.example.com:6443"
        disable_local_ca_jwt = true # OpenBao runs outside this cluster
        ca_cert              = <<-EOT
          -----BEGIN CERTIFICATE-----
          ...
          -----END CERTIFICATE-----
        EOT
        roles = {
          teamc-api = {
            service_accounts = ["teamc-api"]
            namespaces       = ["teamc"]
            token_policies   = ["app-read", "encryption"]
          }
        }
      }
    }
  }
}
