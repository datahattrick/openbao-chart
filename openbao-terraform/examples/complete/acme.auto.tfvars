acme = {
  cluster_url     = "https://openbao.example.com"
  allowed_domains = ["internal.example.com"]

  # Self-signed CA by default. For an intermediate signed by your CA, either:
  #
  # Upstream: your CA's OpenBao signs it in the same apply. Set upstream_address and TF_VAR_upstream_token.
  #   upstream = { namespace = "pki", mount_path = "pki_int" }
  #
  # Manual: set intermediate = true and apply. The acme.csr output is the CSR.
  # Get it signed, save the certificate and its chain to certificate_file, and apply again.
  #   intermediate     = true
  #   certificate_file = "certs/acme-intermediate.pem"
  ca = {
    common_name = "Example ACME Intermediate"
  }
}
