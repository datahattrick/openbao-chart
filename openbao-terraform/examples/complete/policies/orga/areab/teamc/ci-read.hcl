path "secret/data/ci/*" {
  capabilities = ["read"]
}

path "secret/metadata/ci/*" {
  capabilities = ["read", "list"]
}
