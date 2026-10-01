# Audit log isolation

## The goal

Audit records must not reach a container's stdout. Everything on stdout is
collected off the node by the cluster log collector and lands in a
general-purpose log store, which a much wider set of people can read than should
see OpenBao's audit trail.

OpenBao HMAC-SHA256s secret *values* before they ever reach a device, so records
are not plaintext secrets. But request paths, policy names, token accessors,
client IPs and identity metadata are all in the clear — and that metadata is
exactly what you do not want in a shared log store. `log_raw` must stay off;
this chart never sets it.

## The pipeline

```mermaid
flowchart LR
    subgraph pod["openbao pod"]
        bao["OpenBao"]
        so(["stdout"])
    end
    bao -->|"file device<br/>declared first"| pvc[("PVC /openbao/audit<br/><i>durable, cannot fail</i>")]
    bao -->|"http device<br/>Content-Type: application/json"| proxy
    subgraph proxy["audit proxy (OpenTelemetry Collector)"]
        in["webhook_event receiver<br/>TLS :9880"] --> buf[("persistent sending queue<br/>retry with backoff")] --> out["otlphttp exporter"]
    end
    out --> sink[("any OTLP receiver<br/>VictoriaLogs, collector, ...")]
    bao -.->|"operational logs only —<br/>never audit records"| so
    so -.-> collector([node log collector])
    style so fill:#fee,stroke:#c44
```

The proxy is an OpenTelemetry Collector (contrib) deployment: a `webhook_event`
receiver for the audit device's POSTs, a `file_storage` sending queue, and an
OTLP exporter. It sits between OpenBao and your log store because **the http
audit device is synchronous and does not retry**, on OpenBao's request path. The
proxy accepts in ~2ms and deals with the downstream itself.

The generated config has **no `debug` or `file` exporter**, and this chart will
not render one. `auditProxy.logLevel` sets the collector's own diagnostic level,
never record payloads. The pod also carries the common collector-exclusion
annotations as a second line of defence.

The contrib distribution is required: `webhook_event` is not in the core
collector.

## Declarative, not API-managed

Devices are declared in the server config file:

```hcl
audit "file" "file" {
  options { file_path = "/openbao/audit/audit.log", elide_list_responses = "true" }
}
audit "http" "http" {
  options {
    uri     = "http://openbao-audit-proxy.openbao.svc:9880/openbao.audit"
    headers = "{\"Content-Type\":[\"application/json\"]}"
  }
}
```

Consequences:

- applied on startup and SIGHUP, not on demand;
- a config-declared device **cannot be modified through the API** and cannot
  duplicate an API-created device;
- deleting a stanza deletes the device;
- **stanza order is the order they are applied**, and `file` is first on purpose.

`elide_list_responses` is on: list responses can name thousands of secrets, so
eliding them cuts both volume and a real information-leak surface.

## Four failure modes that will cost you an afternoon

### 1. A failed audit device makes the cluster unrecoverable

Config-declared audit devices are created during `operator init`. OpenBao writes
a **test message** through each one. If that fails, the init API call returns
400 — but the barrier has *already* been created. The result is a cluster that
reports `Initialized: true` whose unseal keys were **never returned to anyone**.
It can never be unsealed. The only fix is to destroy the storage and start again.

This is not hypothetical; it happened twice while building this chart.

```mermaid
sequenceDiagram
    participant J as bootstrap
    participant B as OpenBao
    participant P as audit proxy
    J->>B: PUT /v1/sys/init
    B->>B: create barrier, generate unseal keys
    B->>P: test message through audit "http"
    P--xB: 400 (no Content-Type / proxy down)
    B--xJ: 400 failed to create audit device
    Note over B: barrier EXISTS. keys were never returned.<br/>Initialized=true, unrecoverable, forever.
```

The bootstrap Job therefore **pre-flights the audit endpoint before init**,
POSTing a test record with the same method, path and Content-Type OpenBao will
use, and refuses to initialise if it does not get a 2xx.

The dependency is narrower than it looks, and it was measured rather than
assumed. With the proxy scaled to zero, OpenBao starts, unseals, loads BOTH
audit devices and serves requests normally — because *loading* an existing
device does not write a test message. Only *creating* one does. So the proxy is
a dependency of `operator init` and of adding a new audit stanza, not of
everyday startup or rescheduling, and the pre-flight above already covers it.

While the proxy is down, `http` records are simply not shipped; the `file`
device keeps them, so the gap is in the downstream stream, not in the audit
trail itself. Shipping resumes on its own when the proxy returns.

### 2. The Content-Type trap

OpenBao's http audit device does:

```go
req.Header = b.headers.Clone()      // internal/builtin/audit/http/backend.go
```

It **replaces** the request headers with whatever `headers` is configured to,
rather than adding to them. With no `headers` option, the POST goes out with no
`Content-Type` at all.

Receivers reject that. Measured against Fluent Bit's http input, which the proxy
used before the collector:

| Content-Type | Result |
|---|---|
| `application/json` | **201** |
| `application/json; charset=utf-8` | 400 `invalid 'Content-Type'` |
| `text/plain` | 400 `invalid 'Content-Type'` |
| *(absent)* | 400 `header 'Content-Type' is not set` |

So `auditDevices.http.headers` defaults to `Content-Type: ["application/json"]`
and must not be removed. Combined with failure mode 1, dropping it does not
produce a shipping problem — it produces an unrecoverable cluster.

### 3. Default-deny in the downstream namespace

If your log aggregator's namespace has a default-deny ingress policy, shipping
fails with:

```
[output:http] no upstream connections available to <host>:<port>
```

Nothing is lost — records buffer and retry — but nothing arrives, and the only
clue is in the proxy's own log.

This chart does not write the fix for you: the policy belongs in the sink's
namespace, and whoever deploys OpenBao usually neither knows that namespace's
layout nor controls it. Ask its owner for an ingress rule admitting the audit
proxy on the sink port — the proxy's pods carry
`app.kubernetes.io/component: audit-proxy` and the release's
`app.kubernetes.io/instance` label:

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: openbao
        podSelector:
          matchLabels:
            app.kubernetes.io/instance: openbao
            app.kubernetes.io/component: audit-proxy
    ports:
      - port: 24224
        protocol: TCP
```

### 4. Why the proxy is not Fluent Bit

`auditProxy.tls.enabled` defaults on, and the hop works, because the proxy is an
OpenTelemetry Collector. Fluent Bit could not do this job. Measured on one
machine, same certificate, same client, POSTing an audit-shaped record:

| Proxy | TLS handshake | Total per POST |
|---|---:|---:|
| Fluent Bit 4.0.5 | 502ms | **1002ms** |
| otelcol-contrib 0.159.0 | 2.4ms | **2.5ms** |
| Vector 0.51.0 | 1.6ms | **1.8ms** |

Fluent Bit's numbers do not move with four times the CPU, so they are event-loop
constants. The http audit device is synchronous and inherits the context of the
request being audited, so at ~1s per POST every audit write failed:

```
backend failed to log request  backend=http/
  error: failed to perform request: Post "https://…/openbao.audit": context canceled
```

and the audited calls stalled with them: `bao audit list` and the autopilot write
both timed out on a live cluster.

Trust is a separate matter and is handled. The http audit device takes no CA
option, so OpenBao validates the hop against its process trust store;
`openbao.server.extraEnvironmentVars` sets `SSL_CERT_DIR` to the backend CA's
mount, and Go adds that directory to the system roots, so public CAs keep working
for the seal and GitLab OIDC.

## Running the proxy as a sidecar instead

For the strictest isolation, run the proxy on `127.0.0.1` inside the OpenBao pod
so audit records never touch the pod network at all:

```yaml
auditProxy:
  enabled: false          # no separate Deployment
openbao:
  server:
    auditDevices:
      http:
        enabled: true
        host: 127.0.0.1
    extraContainers:
      - name: audit-proxy
        image: docker.io/otel/opentelemetry-collector-contrib:0.159.0
        args: ["--config=/etc/otelcol/config.yaml"]
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits:   {cpu: 500m, memory: 512Mi}
        volumeMounts:
          - {name: audit-proxy-config, mountPath: /etc/otelcol/config.yaml, subPath: config.yaml}
```

Trade-off: one proxy per replica, no aggregation, and you supply the ConfigMap.
It also removes the startup dependency described above only partially — the
sidecar still has to be listening before OpenBao initialises.

## Verifying

```sh
# records arriving downstream
kubectl -n monitoring port-forward svc/<vlsingle> 9428:9428
curl -sG localhost:9428/select/logsql/query \
  --data-urlencode 'query=log_source:"openbao-audit" | stats count() total'

# and NOT on stdout
kubectl -n openbao logs openbao-0 -c openbao | grep -c '"type":"response"'   # expect 0
```
