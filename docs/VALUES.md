# Placeholder values

`values-prod.yaml` ships 16 `CHANGEME-` placeholders. They are non-empty so the
chart renders and lints untouched; the point is that a forgotten one fails
visibly instead of quietly doing the wrong thing.

```sh
grep -n CHANGEME openbao/examples/values-prod.yaml
```

Some mistakes are caught at render time by `_validate.tpl`, which fails with a
message naming the value. The rest fail at deploy, and the tables below say how
— because "PVC stuck Pending" is not an obvious symptom of "wrong storageClass"
at 2am.

## TLS and external access

| Value | What it is | If it is wrong |
|---|---|---|
| `tls.server.issuerRef.name` | Issuer for the **frontend** certificate, and a different CA from the backend. `tls.server.source: cert-manager` only | **Render fails** if it matches the backend issuer. Wrong-but-different: Certificate stays `Ready=False`, pod never gets its cert |
| `tls.server.dnsNames[0]` | Hostname clients use. `tls.server.source: cert-manager` only | **Render fails** if it does not contain `ingress.host` |
| `tls.server.secretName` | The `kubernetes.io/tls` Secret holding the frontend certificate. Under `tls.server.source: secret` you create it; `openbao.server.volumes` must mount the same name | **Render fails** if no volume mounts it. Named but absent: pod stays in `ContainerCreating` |
| `ingress.className` | Your IngressClass | Ingress created, no controller claims it, no `ADDRESS` is assigned |
| `ingress.host` | Public hostname | **Render fails** unless it is also in `tls.server.dnsNames` |
| `ingress.tls.secretName` | Cert the *controller* serves (separate from the frontend listener's) | Controller falls back to its default certificate, so clients see a name mismatch |

If you are **not** on Traefik, also set the re-encrypt annotations under
`ingress.annotations` — the commented nginx block shows the shape. The backend
speaks TLS on 8210, and a controller told to send plaintext fails with a
connection error, or worse, silently downgrades.

## Networking

| Value | What it is | If it is wrong |
|---|---|---|
| `networkPolicy.allowFromNamespaces[0]` | Namespace of your ingress controller | Default-deny drops it. The Ingress looks healthy; requests time out |
| `networkPolicy.monitoring.namespace` | Namespace your scraper runs in | Metrics silently never appear — no error anywhere |

## Audit

| Value | What it is | If it is wrong |
|---|---|---|
| `auditProxy.output.otlphttp.endpoint` | Full OTLP logs URL of your log store | Exporter logs `Exporting failed. Will retry` and records queue on disk. **Nothing is lost**, since the file device on the PVC is the system of record, but nothing ships |

## Backups

| Value | What it is | If it is wrong |
|---|---|---|
| `snapshotAgent.s3.host` | S3 endpoint | CronJob fails at upload; the snapshot itself succeeded |
| `snapshotAgent.s3.bucket` | s3cmd's `--host-bucket`. **Path-style: the bare host.** Vhost-style: `%(bucket)s.<host>` | `403 AccessDenied: Invalid signature`. This reads like bad credentials and is not — the value lands in the SigV4 signing string and stops matching the Host header |
| `snapshotAgent.s3.uri` | `s3://bucket/prefix/` | Uploads land in the wrong place, or the bucket does not exist |
| `snapshotAgent.s3.credentialsSecret` | Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, **in this namespace** | Pod stuck in `CreateContainerConfigError`. Secrets are namespaced, so the credentials need copying into this namespace |

## Storage

| Value | What it is | If it is wrong |
|---|---|---|
| `openbao.server.dataStorage.storageClass` | Raft data. Wants low-latency disk | PVC stays `Pending`; the pod never starts and nothing says why unless you `describe` the PVC |
| `openbao.server.auditStorage.storageClass` | Audit log volume | Same, and the file audit device cannot be created — which **fails `operator init`** and leaves the cluster unrecoverable. See [AUDIT.md](AUDIT.md) |

## GitLab OIDC (only when `bootstrap.gitlab.enabled: true`)

| Value | What it is | If it is wrong |
|---|---|---|
| `bootstrap.gitlab.url` | Your GitLab base URL | Bootstrap fails configuring the auth mount — OIDC discovery cannot resolve |
| `bootstrap.gitlab.audience` | Must equal `aud` in the pipeline's `id_tokens` block | Every pipeline login fails with `invalid audience` |

Also uncomment `bootstrap.gitlab.policies` and `roles`. **A role with no
`bound_claims` lets any pipeline on the instance assume it** — the JWT is
perfectly valid, it just came from someone else's project. Bind at least
`project_path`; for a role that can write, bind `ref` and `ref_protected` too.

## Auto-unseal — still to decide

`values-prod.yaml` leaves auto-unseal off, so it deploys on Shamir, meaning a
human unseals every node after every restart. Layer `values-azure.yaml` or
`values-transit.yaml` and set `bootstrap.init.autoUnseal: true`. See
[SEAL.md](SEAL.md).
