# openbao-terraform

An OpenTofu module that configures OpenBao namespaces from variables.
Each namespace is one entry in a map, keyed by its full path.

## Requirements

1. OpenTofu 1.11 or later (write-only attributes).
2. OpenBao 2.3 or later (namespaces). Tested against 2.7.1.
3. The `hashicorp/vault` provider 5.x, configured with `VAULT_ADDR` and `VAULT_TOKEN` for an identity in the root namespace.
4. One OIDC client per branch and leaf namespace, with redirect URIs `https://<openbao>/ui/vault/auth/oidc/oidc/callback` and `http://localhost:8250/oidc/callback`.
   The groups claim (default `groups`) must carry the IdP group names used in `admin_groups` and `groups`.

## Namespace types

```
root                  no logins
└── orga              container
    ├── areab         container
    │   └── teamc     leaf: teamc-admins, teamc-developers log in here
    └── aread         branch: aread-admins log in here
        └── ...       created by aread-admins
```

| Type | Logins | Admins | Secrets and workload auth | OpenTofu children |
|---|:---:|:---:|:---:|:---:|
| `container` | ❌ | ❌ | ❌ | ✅ |
| `branch` | ✅ | ✅ required | ❌ | ✅ |
| `leaf` | ✅ | ✅ optional | ✅ | ❌ |

Admins have full control of their namespace and everything below it, including creating child namespaces.
Nobody logs in at root or in a container.
Above a branch or leaf, only the OpenTofu identity and root token holders have access.

## Usage

```hcl
oidc_defaults = {
  discovery_url = "https://login.example.com/realms/corp"
  ui_url        = "https://openbao.example.com"
}

namespaces = {
  "orga"       = { type = "container" }
  "orga/areab" = { type = "container" }

  "orga/areab/teamc" = {
    type         = "leaf"
    oidc         = { client_id = "openbao-orga-areab-teamc" }
    admin_groups = ["teamc-admins"]
    groups       = { teamc-developers = ["app-read"] }
    kv           = { secret = {} }
  }
}
```

```bash
export TF_VAR_oidc_client_secrets='{"orga/areab/teamc":"..."}'
tofu apply
```

Policies are read from `policies/<namespace path>/<policy name>.hcl`, for example `policies/orga/areab/teamc/app-read.hcl`.
A namespace's `policies` map adds inline ones.

[examples/complete](examples/complete) is a root configuration with every option in [namespaces.auto.tfvars](examples/complete/namespaces.auto.tfvars).
Full types and defaults are in [variables.tf](modules/openbao/variables.tf).

## Features

- **Namespace types** with the rules above checked at plan time, naming the namespaces that break them.
- **OIDC login** in each branch and leaf. Shared settings go in `oidc_defaults`. Client secrets are write-only and are not stored in state.
- **IdP group mapping**: `admin_groups` get the built-in `namespace-admin` policy, `groups` map other IdP groups to policies.
- **Policies** from files or inline.
- **KV v2** mounts with version limits, check-and-set, and version expiry.
- **Other secrets engines** (transit, pki, database, ...) by type and options.
- **AppRole** auth, with CIDR binding on tokens and secret IDs. Role IDs are an output.
- **Kubernetes** auth, one mount per cluster.
- **ACME** certificate issuance from its own namespace, with a self-signed CA or an intermediate signed by an upstream OpenBao or by hand. [Detail](#acme)
- **Deletion protection** on namespaces, secrets mounts and the ACME CA key. [Detail](#deletion-protection)

## Inputs

| Input | Purpose |
|---|---|
| `namespaces` | Map of namespace path to settings. Every parent must be listed. |
| `oidc_defaults` | OIDC settings shared by all namespaces. A namespace's `oidc` overrides them per field. |
| `oidc_client_secrets` | Ephemeral map of namespace path to client secret. Bump that namespace's `oidc.client_secret_version` to rotate. |
| `policies_dir` | Root of the policy file tree. |

| Namespace field | Types |
|---|---|
| `type`, `custom_metadata` | all |
| `oidc` | branch, leaf (required) |
| `admin_groups` | branch (required), leaf |
| `groups`, `policies` | branch, leaf |
| `kv`, `secrets_engines`, `approle`, `kubernetes` | leaf |

Outputs are `namespaces` (path to ID), `approle_role_ids` and `auth_accessors`, keyed by `"<namespace>:<name>"` where not a path.

## ACME

`acme` creates an `acme` namespace under root with a PKI mount configured as an ACME server.
It has no logins. ACME clients use the unauthenticated ACME endpoints.

```hcl
acme = {
  cluster_url     = "https://openbao.example.com"
  allowed_domains = ["internal.example.com"]
}
```

The directory URL is `https://openbao.example.com/v1/acme/pki/acme/directory`, also in the `acme.directory_url` output.
Clients may request names under `allowed_domains`. Others fail with `urn:ietf:params:acme:error:rejectedIdentifier`.
Certificates last 30 days by default, at most 90.
ACME clients require HTTPS on `cluster_url`.

The CA is self-signed by default, for testing.
For an intermediate signed by your CA, OpenBao generates the key, which never leaves it, and a CSR.
The CSR is signed in one of two ways.

### Signed by an upstream OpenBao

The upstream OpenBao signs the CSR in the same apply.

```hcl
ca = {
  common_name = "Example ACME Intermediate"
  upstream    = { namespace = "pki", mount_path = "pki_int" }
}
```

The module takes a second provider, `vault.upstream`, for the upstream OpenBao:

```hcl
provider "vault" {
  alias            = "upstream"
  address          = var.upstream_address
  token            = var.upstream_token
  skip_child_token = true
}

module "openbao" {
  source    = "./modules/openbao"
  providers = { vault = vault, vault.upstream = vault.upstream }
  # ...
}
```

Pass `vault.upstream = vault` when `upstream` is not used. The upstream provider is not contacted then.

The upstream token needs one policy, written where it authenticates:

```hcl
path "pki/pki_int/root/sign-intermediate" {
  capabilities = ["update"]
}
```

With `issuer_ref` set, the path is `pki/pki_int/issuer/<issuer_ref>/sign-intermediate` instead.

The intermediate is signed with `pathlen:0` and a name constraint for `allowed_domains`.
Set `name_constraints = false` if your CA does not allow them.
Its lifetime is `ttl`, default 5 years, capped by the upstream mount.
To renew it, bump `renew`. Changing any other `upstream` field also signs it again.
ACME switches to the new certificate. Older ones stay as issuers until they expire.

If signing fails, for example with `Code: 403`, the previous CA keeps issuing.

### Signed by hand

1. Set `ca = { common_name = "...", intermediate = true }` and apply.
   The `acme.csr` output holds the CSR. The self-signed CA keeps issuing meanwhile.
2. Have your CA sign it as a CA certificate (`basicConstraints = CA:true`, `keyUsage = keyCertSign, cRLSign`).
   Save it, followed by its chain, to a file and set `certificate_file` to that path, relative to where `tofu` runs.
3. Apply. The intermediate becomes the issuer and the self-signed CA is deleted.

The `acme.ca_chain` output holds the issuing CA's chain for clients to trust.
Full options are in [modules/acme/variables.tf](modules/openbao/modules/acme/variables.tf).

## Deletion protection

Namespaces, `kv` and `secrets_engines` mounts, the ACME namespace, its PKI mount and its intermediate key cannot be destroyed by OpenTofu.
A plan that would destroy one fails before anything is applied, with `Resource instance cannot be destroyed`.
That includes removing a namespace or mount from the variables, renaming one, changing the ACME CA's `common_name` or key, and `tofu destroy`.

To delete one on purpose, delete it with `bao`, then `tofu state rm` it and remove it from the variables.

## Known issues

- Namespaces can be at most 6 levels deep.
- Policies, auth methods, roles and groups are not protected. Removing them from the variables deletes them.
- Changes made by admins to resources this module manages, such as the OIDC config or `namespace-admin`, are reverted on the next apply.
- A group cannot have members from another namespace. OpenBao returns `invalid member group ID`.
- Kubernetes auth without `ca_cert` reads the CA from the OpenBao pod.
  Outside the cluster this fails with `open /var/run/secrets/kubernetes.io/serviceaccount/ca.crt: no such file or directory`.
  Set `ca_cert` and `disable_local_ca_jwt = true`.
- Audit devices are not managed here.
  Declare them in the server configuration's `audit` stanza.
  Creating them over the API needs `unsafe_allow_api_audit_creation`.

## Future

- ACME external account binding tokens
- Transit keys
- Database connections and roles
- Rate limit quotas
- Password policies
