variable "namespace" {
  description = "Name of the namespace, created under root."
  type        = string
  default     = "acme"
}

variable "mount_path" {
  description = "Path of the PKI mount in the namespace."
  type        = string
  default     = "pki"
}

variable "cluster_url" {
  description = "Public OpenBao URL that ACME clients reach, e.g. https://openbao.example.com."
  type        = string
}

variable "allowed_domains" {
  description = "Domains ACME clients may request certificates for."
  type        = list(string)
}

variable "allow_subdomains" {
  type    = bool
  default = true
}

variable "allow_bare_domains" {
  type    = bool
  default = false
}

variable "allow_wildcard_certificates" {
  type    = bool
  default = false
}

variable "allow_ip_sans" {
  type    = bool
  default = false
}

variable "ttl" {
  description = "Default certificate lifetime, in seconds."
  type        = number
  default     = 2592000 # 30 days
}

variable "max_ttl" {
  description = "Maximum certificate lifetime, in seconds."
  type        = number
  default     = 7776000 # 90 days
}

variable "eab_policy" {
  description = "not-required, new-account-required or always-required."
  type        = string
  default     = "not-required"

  validation {
    condition     = contains(["not-required", "new-account-required", "always-required"], var.eab_policy)
    error_message = "eab_policy must be not-required, new-account-required or always-required."
  }
}

variable "dns_resolver" {
  description = "host:port of the DNS server used to validate challenges. null uses the system resolver."
  type        = string
  default     = null
}

variable "ca" {
  description = <<-EOT
    The issuing CA. One of:
      self-signed (default): for testing.
      manual:   intermediate = true. OpenBao generates a key and CSR (the csr output).
                Sign the CSR with your CA and set certificate or certificate_file to the signed certificate,
                optionally followed by its chain. The self-signed CA keeps issuing until then.
      upstream: an upstream OpenBao signs the CSR in the same apply, through the vault.upstream provider.
  EOT
  type = object({
    common_name      = optional(string, "OpenBao ACME CA")
    organization     = optional(string)
    key_type         = optional(string, "ec")
    key_bits         = optional(number, 256)
    self_signed_ttl  = optional(string, "8760h")
    intermediate     = optional(bool, false)
    certificate      = optional(string)
    certificate_file = optional(string)
    upstream = optional(object({
      mount_path = string
      namespace  = optional(string)
      # null signs with the mount's default issuer, via <mount_path>/root/sign-intermediate.
      # Set it to use <mount_path>/issuer/<issuer_ref>/sign-intermediate instead.
      issuer_ref = optional(string)
      ttl        = optional(string, "43800h") # 5 years, capped by the upstream mount
      # Limit the intermediate to allowed_domains, so it cannot sign for other names.
      name_constraints = optional(bool, true)
      # Bump to have the intermediate signed again, e.g. before it expires. Changing any field above also does.
      renew = optional(number, 0)
    }))
  })
  default = {}

  validation {
    condition     = var.ca.certificate == null || var.ca.certificate_file == null
    error_message = "Set ca.certificate or ca.certificate_file, not both."
  }

  validation {
    condition     = var.ca.upstream == null || (var.ca.certificate == null && var.ca.certificate_file == null)
    error_message = "ca.upstream signs the certificate, so ca.certificate and ca.certificate_file must be unset."
  }

  validation {
    condition     = var.ca.intermediate || (var.ca.certificate == null && var.ca.certificate_file == null)
    error_message = "ca.certificate needs ca.intermediate = true, so that OpenBao holds the matching key."
  }
}
