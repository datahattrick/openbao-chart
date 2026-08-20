# Architecture

## Components

```mermaid
flowchart TB
    subgraph ext[" "]
        client([client / operator])
        gitlab([GitLab CI])
    end

    subgraph edge["kube-system"]
        traefik["Traefik<br/><i>or OpenShift Router</i>"]
    end

    subgraph ns["namespace: openbao"]
        direction TB
        svcF["Service<br/>openbao-frontend :8210"]
        sts["StatefulSet openbao-N<br/>:8200 backend · :8210 frontend · :8201 cluster"]
        boot["Job openbao-bootstrap<br/><i>completions 1, parallelism 1</i>"]
        proxy["Deployment openbao-audit-proxy<br/>Fluent Bit :9880"]
        cron["CronJob openbao-snapshot"]
        pki["cert-manager<br/>backend CA (Issuer)"]
        keys[("Secret<br/>openbao-init-keys")]
        data[("PVC data<br/>raft")]
        audit[("PVC audit<br/>audit.log")]
    end

    subgraph other["other namespaces"]
        s3[("S3 / Garage")]
        logs[("Fluent Bit /<br/>VictoriaLogs")]
    end

    client -->|"TLS: frontend CA"| traefik
    traefik -->|"re-encrypt<br/>frontend CA"| svcF --> sts
    gitlab -->|"OIDC ID token"| traefik

    boot -->|"init · unseal · configure"| sts
    boot -->|writes then revokes root| keys
    keys -.->|"mounted read-only"| sts
    pki -->|"issues"| sts
    sts --- data
    sts -->|file device| audit
    sts -->|"http device<br/>synchronous, no retry"| proxy
    proxy -->|"buffered + retried"| logs
    cron -->|"OIDC login<br/>+ snapshot read"| sts
    cron -->|upload| s3

    classDef store fill:#eef,stroke:#88a
    class keys,data,audit,s3,logs store
```

## The two trust domains

The central design decision. Two listeners on the same pod, each presenting a
certificate from a **different** CA, with only one of them reachable by a raft
peer.

```mermaid
flowchart LR
    subgraph fe["FRONTEND trust domain"]
        feca["frontend CA<br/><i>ClusterIssuer: grom-ca,<br/>corporate, ACME…</i>"]
        fecert["Certificate<br/>openbao-tls-server"]
        feca --> fecert
    end

    subgraph be["BACKEND trust domain"]
        beca["backend CA<br/><i>namespaced Issuer,<br/>created by this chart</i>"]
        becert["Certificate<br/>openbao-tls-internal"]
        beca --> becert
    end

    fecert --> l8210["listener :8210<br/><b>no cluster_address</b>"]
    becert --> l8200["listener :8200<br/>cluster_address :8201"]

    ingress["Ingress / Route"] --> l8210
    peers["raft retry_join<br/>leader_ca_cert_file"] --> l8200
    incluster["probes · snapshot agent ·<br/>metrics · injector"] --> l8200

    l8201["cluster port :8201<br/><i>certs generated and rotated<br/>by OpenBao itself</i>"]
    l8200 -.->|"mTLS exchanged at join time"| l8201

    style be fill:#efe,stroke:#4a4
    style fe fill:#fef,stroke:#a4a
    style l8201 fill:#eee,stroke:#999,stroke-dasharray: 4 4
```

**Why it holds.** `retry_join.leader_ca_cert_file` names the backend CA and
nothing else. A certificate signed by the frontend CA is not valid for any peer
address and would not be accepted on a join, so compromising the public or
corporate CA does not get an attacker into the raft cluster.

Verified directly — the backend listener accepts the backend CA and rejects the
frontend CA:

```
:8200 with backend CA  → HTTP 200
:8200 with frontend CA → SSL certificate problem: unable to get local issuer certificate
```

**cert-manager cannot own port 8201.** OpenBao generates and rotates the cluster
port's mTLS certificates itself and exchanges them over the API port when a node
joins. The seam cert-manager *can* own is the API-port certificate the join
handshake is validated against — which is the one that matters.

**The backend CA is a namespaced `Issuer`, not a `ClusterIssuer`.** A
ClusterIssuer is referenceable from any namespace, so anyone able to create a
Certificate anywhere in the cluster could mint something a raft join would trust.
Namespacing it makes that impossible without RBAC in this namespace.

### Why the ports look backwards

The backend is on 8200 and the frontend on 8210, which is the reverse of the
intuitive layout. The upstream chart hardcodes 8200 in its readiness probe,
Services, Kubernetes service registration and snapshot-agent ConfigMap. Putting
the *in-cluster* trust domain there means all of that keeps working untouched;
the frontend is the one thing only the Ingress needs to reach, so it is the one
that moves.

## Bootstrap sequence

```mermaid
sequenceDiagram
    autonumber
    participant J as bootstrap Job
    participant P as audit proxy
    participant B as openbao-0
    participant K as Secret

    J->>P: POST test record (Content-Type: application/json)
    Note over J,P: refuses to continue without a 2xx —<br/>a failing audit device makes init unrecoverable
    P-->>J: 201

    J->>B: GET sys/seal-status
    B-->>J: initialized=false

    J->>B: operator init (5 shares / threshold 3)
    B-->>J: unseal keys + root token
    J->>K: write keys
    Note over J,K: written BEFORE any unsealing —<br/>a crash after init but before this<br/>loses the cluster permanently

    loop each replica
        J->>B: operator unseal × threshold
    end

    J->>B: raft autopilot config
    J->>B: policy write raft-snapshot, opentofu
    J->>B: auth enable jwt @ kubernetes/
    J->>B: auth config (provider_config: kubernetes)
    J->>B: role bao-snapshot (bound aud + subject)
    J->>B: list-peers / audit list / auth list

    J->>B: token revoke -self
    J->>K: delete root-token, add root-token-revoked
    Note over J,K: unseal keys retained —<br/>generate-root can mint a new one
```

## Where values must agree

Helm does not template subchart values, so several settings are coupled across
the boundary and the coupling is invisible. `templates/_validate.tpl` turns each
one into a render-time failure naming the value to fix, rather than a deployment
that renders perfectly and silently cannot connect.

```mermaid
flowchart LR
    subgraph umbrella["this chart's values"]
        t1["tls.server.port"]
        t2["tls.internal.port"]
        t3["tls.*.secretName"]
        t4["bootstrap.kubernetesAuth.path"]
        t5["bootstrap.snapshot.role"]
        t6["auditProxy.listen.port / .tag"]
    end
    subgraph sub["openbao.* (subchart)"]
        s1["server.extraPorts[https-frontend]"]
        s2["server.service.port"]
        s3["server.volumes[].secret"]
        s4["snapshotAgent.config.baoAuthPath"]
        s5["snapshotAgent.config.baoRole"]
        s6["server.auditDevices.http.*"]
    end
    t1 <-->|checked| s1
    t2 <-->|checked| s2
    t3 <-->|checked| s3
    t4 <-->|checked| s4
    t5 <-->|checked| s5
    t6 <-->|checked| s6
```

Other checks: issuer separation (frontend and backend must not share an issuer),
odd raft replica counts, `file` audit device present whenever `http` is, audit
storage enabled when the file device is, and restore requiring a token that will
still exist after root revocation.

## Release naming

Subchart resource names derive from the **release** name. The TLS and init
Secret names in `values.yaml` are literals matching a release called `openbao`,
because subchart values cannot be templated. Renaming the release fails the
render with an explicit message; to actually rename it, change the literals in
`tls.*.secretName`, `bootstrap.keyOutput.secretName` and
`openbao.server.volumes` together.
