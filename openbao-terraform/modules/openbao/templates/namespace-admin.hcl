# Full control of this namespace and every namespace below it.
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
