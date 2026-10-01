module "acme" {
  source = "./modules/acme"
  count  = var.acme == null ? 0 : 1

  providers = {
    vault          = vault
    vault.upstream = vault.upstream
  }

  namespace                   = var.acme.namespace
  mount_path                  = var.acme.mount_path
  cluster_url                 = var.acme.cluster_url
  allowed_domains             = var.acme.allowed_domains
  allow_subdomains            = var.acme.allow_subdomains
  allow_bare_domains          = var.acme.allow_bare_domains
  allow_wildcard_certificates = var.acme.allow_wildcard_certificates
  allow_ip_sans               = var.acme.allow_ip_sans
  ttl                         = var.acme.ttl
  max_ttl                     = var.acme.max_ttl
  eab_policy                  = var.acme.eab_policy
  dns_resolver                = var.acme.dns_resolver
  ca                          = var.acme.ca
}
