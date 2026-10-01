output "directory_url" {
  description = "ACME directory URL to give ACME clients."
  value       = "${local.base_url}/acme/directory"
}

output "csr" {
  description = "CSR for the intermediate, to sign with your CA. null unless ca.intermediate is set."
  value       = one(vault_pki_secret_backend_intermediate_cert_request.this[*].csr)
}

output "issuer_id" {
  description = "ID of the issuer ACME certificates are signed by."
  value       = local.issuer_id
}

output "ca_chain" {
  description = "PEM chain of the issuing CA, for clients to trust."
  value       = data.vault_pki_secret_backend_issuer.default.ca_chain
}
