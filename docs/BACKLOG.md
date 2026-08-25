# Backlog

Findings from the design review that were deliberately not actioned. Ordered by
what would bite first.

## Done

- **Init keys leaked into an annotation.** `kubectl apply` records the whole
  object in `kubectl.kubernetes.io/last-applied-configuration`, so the root
  token and every unseal key had a second copy in an annotation — and deleting
  `.data.root-token` during revocation left that copy behind. Now
  `kubectl apply --server-side`, which writes no such annotation, plus a
  cleanup step for Secrets written by older releases. Verified on a clean
  install: no annotations at all.
- **Certificates never reloaded after renewal.** Fixed with a SIGHUP sidecar;
  see `openbao.server.tlsReload`. Verified by forcing a renewal and watching
  the serial on the socket change, with zero restarts.
- **No scheduling priority.** Added `priorityClassName`, chart-wide with
  per-component overrides, applied to the StatefulSet, audit proxy, bootstrap
  Job, snapshot CronJob, restore Job and the helm test. `system-cluster-critical`
  is usable outside kube-system (verified by server-side dry-run). The render
  fails if the chart-wide value is set but `openbao.server.priorityClassName`
  is not, so the workload that matters most cannot be left unprioritised.
- **`keyOutput.mountIntoServer` now defaults to false.** While on, anyone who
  can `exec` into an OpenBao pod could read the unseal keys — wider than `get
  secret` on one named Secret. The volume and mount are commented out of base
  values so the flag genuinely controls the exposure, and validation enforces
  the pairing in both directions.
- **Revoking the root token could have locked the cluster out permanently.**
  Since v2.5.3 `disable_unauthed_generate_root_endpoints` defaults to **true**,
  so `/sys/generate-root/*` is not served and no replacement root token can be
  minted — while this chart revoked the initial token by default. Now enabled
  on the **backend** listener only (never through the Ingress), with validation
  refusing `revokeRootToken` without it. Verified: the endpoint returned
  `unsupported operation` before and a full attempt/update/cancel cycle after.
  Separately, `bao operator generate-root` calls a legacy path that 403s on
  2.6.x — docs now give the working API calls.
- **Snapshot CronJob ran with `concurrencyPolicy: Allow`.** This chart now owns
  the CronJob (the subchart exposes only `schedule`), set to `Forbid`, daily.

## Open

### 1. No alerting  — deferred to another environment
Silent failure modes with no signal: a failed snapshot Job, a sealed node, a
certificate near expiry, a lost raft peer, the audit proxy dropping records.
A `VMRule` with five rules is the highest value-per-line work remaining.

### 2. Shamir clusters need a human after any restart
Under Shamir there is no automatic unseal. A node reboot, an eviction or a
`kubectl delete pod` to pick up config leaves the cluster sealed until someone
intervenes — the bootstrap Job only runs on `helm upgrade`.
Unsealing by hand is a mitigation, not a fix.
**Auto-unseal is the fix** (`values-azure.yaml` / `values-transit.yaml`).
Until then, treat any restart of a Shamir cluster as a planned operation.

### 3. Switch `tlsReload.method` to `auto` once available
`tls_auto_reload` on the listener replaces the sidecar entirely — no extra
container and no `shareProcessNamespace`. It is **not in v2.6.2** (PR #3530
landed on main afterwards; there is no v2.7.0 release yet). On an older binary
OpenBao only *warns* about the unknown field, so it looks applied and silently
is not — `_validate.tpl` refuses the combination for that reason. Revisit on
the next release: set `method: auto`, empty `extraContainers`, and drop
`shareProcessNamespace`.

### 4. Audit proxy availability — TESTED, and much narrower than first written

The original finding claimed the `http` audit device made the proxy a hard
dependency of OpenBao's startup, and proposed a PDB, a DaemonSet or a sidecar.
**That was wrong.** Measured on a live cluster with the proxy scaled to zero:

| Event | Depends on the audit proxy? |
|---|---|
| Process start | **No** — starts clean, 0 restarts |
| Unseal | **No** — unsealed normally with the endpoint unreachable |
| Loading existing audit devices | **No** — both `file/` and `http/` logged `enabled audit backend` |
| Serving requests | **No** — ingress kept returning 200 |
| **`operator init`** (first-time device *creation*) | **Yes** — hard failure, and it leaves the cluster unrecoverable |

The distinction is creation versus loading. Creating a device writes a test
message through it, so a dead endpoint fails the call; *loading* an already
existing device does not. Only `operator init` (and, by the same path, adding a
new audit stanza to a cluster that did not have it) touches the endpoint.

That case is already covered by the bootstrap's pre-flight, which refuses to
initialise until the endpoint accepts a test record. **No PDB, DaemonSet or
sidecar is warranted**, and a sidecar would be actively worse: one proxy per
replica once the cluster is scaled out, each buffering independently.

What remains is smaller and is a shipping concern, not an availability one:
while the proxy is down the `http` device fails per-request and those records
are **not shipped**. Nothing is lost — the `file` device on the PVC is the
system of record and still has them — but the downstream stream has a gap for
the outage, and Fluent Bit's buffer only covers a downstream outage, not one
where the proxy itself is gone.

Verified recovery: scaling the proxy back to 1 resumed shipping with no
intervention (154 → 158 records after an audited request).

**Residual work:** backfilling the gap would mean tailing the audit PVC as a
second Fluent Bit input. Worth it only if a continuous shipped stream is a
compliance requirement rather than a convenience.

### 5. No Shamir → auto-unseal migration path documented
Relevant now: heathernetes is Shamir and the two new environments will not be.
Migrating an existing initialised cluster to a seal is a real procedure
(`seal`/`disabled` stanza pairs, `operator unseal -migrate`) and none of it is
written down here.

### 6. Bootstrap Jobs accumulate
One per release revision, kept on purpose so their logs remain the record of
what was configured and when — but unbounded. Either set
`bootstrap.ttlSecondsAfterFinished` or prune periodically.

### 7. Bootstrap pre-flight records pollute the audit stream
Every upgrade POSTs a `bootstrap-preflight` record to the real audit endpoint,
so it lands in the audit store alongside genuine records. It should go to a
separate URI path (and therefore a separate Fluent Bit tag) that the pipeline
routes to /dev/null.

### 8. Restore Job hardcodes an 8Gi scratch volume
`emptyDir: sizeLimit: 8Gi` in `restore-job.yaml`. A larger snapshot fails at
download time. Make it a value.

### 9. `values-transit.yaml` references Secrets nothing creates
`openbao-transit-unseal` (the token) and `openbao-transit-ca` must exist before
install, and neither is created nor validated. Either add a pre-flight check or
document them alongside the values.
