# Types and documentation live in modules/openbao/variables.tf.

variable "namespaces" {
  type = any
}

variable "oidc_defaults" {
  type    = any
  default = {}
}

variable "oidc_client_secrets" {
  description = "Set via TF_VAR_oidc_client_secrets, keyed by namespace path."
  type        = map(string)
  default     = {}
  ephemeral   = true
}

variable "acme" {
  type    = any
  default = null
}

variable "upstream_address" {
  description = "Address of the upstream OpenBao that signs the ACME intermediate."
  type        = string
  default     = null
}

variable "upstream_token" {
  description = "Token for the upstream OpenBao. Set via TF_VAR_upstream_token."
  type        = string
  default     = null
  ephemeral   = true
}
