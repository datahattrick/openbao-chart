{{/*
Cross-value consistency checks.

Several settings live in this chart's values but are consumed inside the
subchart, where templates cannot reach them (Helm does not template subchart
values). The couplings are therefore real but invisible, and getting one wrong
produces a deployment that renders perfectly and then quietly fails to form a
raft cluster or authenticate the snapshot agent.

Each check below turns exactly one such silent failure into a render-time error
naming the value to fix.
*/}}
{{- define "obp.validate" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- $server := $bao.server | default dict -}}
{{- $global := $bao.global | default dict -}}
{{- $ha := $server.ha | default dict -}}
{{- $fullname := include "obp.baoFullname" . -}}

{{/* --- TLS master switch -------------------------------------------------- */}}
{{- if and .Values.tls.enabled $global.tlsDisable }}
{{- fail "openbao-platform: tls.enabled is true but openbao.global.tlsDisable is also true. The listeners in the raft config terminate TLS, so the subchart must be told TLS is on. Set openbao.global.tlsDisable=false." }}
{{- end }}
{{- if and (not .Values.tls.enabled) (not $global.tlsDisable) }}
{{- fail "openbao-platform: tls.enabled is false but openbao.global.tlsDisable is false. Set openbao.global.tlsDisable=true, and replace openbao.server.ha.raft.config with a plaintext listener." }}
{{- end }}

{{/* --- frontend listener <-> extraPorts ----------------------------------- */}}
{{- $frontendPort := 0 -}}
{{- range $server.extraPorts }}
  {{- if eq (.name | default "") "https-frontend" }}
    {{- $frontendPort = .containerPort }}
  {{- end }}
{{- end }}
{{- if .Values.tls.server.enabled }}
  {{- if not $frontendPort }}
{{- fail "openbao-platform: tls.server.enabled is true but openbao.server.extraPorts has no entry named 'https-frontend'. The raft config emits the frontend listener only when that port exists, so the certificate would be issued and never served. Add it, or set tls.server.enabled=false." }}
  {{- end }}
  {{- if ne (int $frontendPort) (int .Values.tls.server.port) }}
{{- fail (printf "openbao-platform: tls.server.port is %v but openbao.server.extraPorts 'https-frontend' declares containerPort %v. The listener binds the extraPorts value; the Ingress/Route targets tls.server.port. Make them equal." .Values.tls.server.port $frontendPort) }}
  {{- end }}
{{- else if $frontendPort }}
{{- fail "openbao-platform: tls.server.enabled is false but openbao.server.extraPorts still declares 'https-frontend'. The raft config would emit a frontend listener whose certificate is never issued and OpenBao would fail to start. Remove the port." }}
{{- end }}

{{/* --- backend listener port ---------------------------------------------- */}}
{{- if ne (int .Values.tls.internal.port) (int ($server.service).port) }}
{{- fail (printf "openbao-platform: tls.internal.port is %v but openbao.server.service.port is %v. The backend listener, the readiness probe, service registration and the snapshot agent all key off the service port." .Values.tls.internal.port ($server.service).port) }}
{{- end }}

{{/* --- server volumes actually mount the certs we issue -------------------- */}}
{{- if .Values.tls.enabled }}
  {{- $vols := $server.volumes | default list -}}
  {{- $want := include "obp.internalTlsSecret" . -}}
  {{- $found := false -}}
  {{- range $vols }}{{- if and .secret (eq (.secret.secretName | default "") $want) }}{{- $found = true }}{{- end }}{{- end }}
  {{- if not $found }}
{{- fail (printf "openbao-platform: no entry in openbao.server.volumes mounts the backend TLS Secret %q. Certificates would be issued but the server would start without them. Either set tls.internal.secretName to a name already listed there, or update openbao.server.volumes (this is the usual symptom of renaming the Helm release: the default secret name is derived from it)." $want) }}
  {{- end }}
  {{- if .Values.tls.server.enabled }}
    {{- $wantS := include "obp.serverTlsSecret" . -}}
    {{- $foundS := false -}}
    {{- range $vols }}{{- if and .secret (eq (.secret.secretName | default "") $wantS) }}{{- $foundS = true }}{{- end }}{{- end }}
    {{- if not $foundS }}
{{- fail (printf "openbao-platform: no entry in openbao.server.volumes mounts the frontend TLS Secret %q. Update openbao.server.volumes, or set tls.server.secretName to match what is listed there." $wantS) }}
    {{- end }}
  {{- end }}
{{- end }}

{{/* --- init key Secret mount ---------------------------------------------- */}}
{{- if and .Values.bootstrap.enabled .Values.bootstrap.keyOutput.mountIntoServer }}
  {{- $wantK := include "obp.initKeysSecret" . -}}
  {{- $foundK := false -}}
  {{- range ($server.volumes | default list) }}{{- if and .secret (eq (.secret.secretName | default "") $wantK) }}{{- $foundK = true }}{{- end }}{{- end }}
  {{- if not $foundK }}
{{- fail (printf "openbao-platform: bootstrap.keyOutput.mountIntoServer is true but no entry in openbao.server.volumes mounts Secret %q. The keys would be written and never appear on the pod. Add it (with optional: true, so pods start before the Job has run) or set mountIntoServer=false." $wantK) }}
  {{- end }}
{{- end }}

{{/* --- break-glass root generation ------------------------------------------ */}}
{{- if .Values.bootstrap.revokeRootToken }}
  {{- $gre := ($server.generateRootEndpoints) | default dict }}
  {{- if not $gre.backend }}
{{- fail "openbao-platform: bootstrap.revokeRootToken is true but openbao.server.generateRootEndpoints.backend is false. Since v2.5.3 `disable_unauthed_generate_root_endpoints` defaults to TRUE, so /sys/generate-root/* is not served and `bao operator generate-root` cannot mint a replacement — revoking the initial root token would lock you out of administering this cluster permanently. Enable it on the backend listener (it is never exposed through the Ingress), or set revokeRootToken=false." }}
  {{- end }}
{{- end }}

{{/* --- init key mount, both directions ------------------------------------- */}}
{{- if not .Values.bootstrap.keyOutput.mountIntoServer }}
  {{- $wantK := include "obp.initKeysSecret" . -}}
  {{- range ($server.volumes | default list) }}
    {{- if and .secret (eq (.secret.secretName | default "") $wantK) }}
{{- fail (printf "openbao-platform: bootstrap.keyOutput.mountIntoServer is false but openbao.server.volumes still mounts Secret %q, so the unseal keys are readable by anyone who can exec into an OpenBao pod. Remove the volume and its volumeMount, or set mountIntoServer=true if that exposure is intended." $wantK) }}
    {{- end }}
  {{- end }}
{{- end }}

{{/* --- priority class ------------------------------------------------------- */}}
{{- if and .Values.priorityClassName (not $server.priorityClassName) }}
{{- fail (printf "openbao-platform: priorityClassName is set to %q for this chart's workloads, but openbao.server.priorityClassName is empty — so the OpenBao StatefulSet, the one workload whose eviction matters most, would be left unprioritised. Helm cannot template subchart values, so set openbao.server.priorityClassName too (or clear the top-level value)." .Values.priorityClassName) }}
{{- end }}

{{/* --- snapshot agent wiring ---------------------------------------------- */}}
{{- if ($bao.snapshotAgent).enabled }}
{{- fail "openbao-platform: openbao.snapshotAgent.enabled must stay false — this chart ships its own CronJob so that concurrencyPolicy can be set (the subchart's template does not expose it). Use the top-level `snapshotAgent` section instead." }}
{{- end }}
{{- $snap := .Values.snapshotAgent }}
{{- if $snap.enabled }}
  {{- if ne $snap.auth.path .Values.bootstrap.kubernetesAuth.path }}
{{- fail (printf "openbao-platform: snapshotAgent.auth.path is %q but bootstrap.kubernetesAuth.path is %q. The agent would log in against an auth mount the bootstrap never created." $snap.auth.path .Values.bootstrap.kubernetesAuth.path) }}
  {{- end }}
  {{- if ne $snap.auth.role .Values.bootstrap.snapshot.role }}
{{- fail (printf "openbao-platform: snapshotAgent.auth.role is %q but bootstrap.snapshot.role is %q. The agent would request a role that does not exist." $snap.auth.role .Values.bootstrap.snapshot.role) }}
  {{- end }}
  {{- if ne $snap.auth.audience .Values.bootstrap.kubernetesAuth.audience }}
{{- fail (printf "openbao-platform: snapshotAgent.auth.audience is %q but bootstrap.kubernetesAuth.audience is %q. The JWT role binds that audience, so every login would fail with 'invalid audience'." $snap.auth.audience .Values.bootstrap.kubernetesAuth.audience) }}
  {{- end }}
  {{- if not .Values.bootstrap.snapshot.enabled }}
{{- fail "openbao-platform: snapshotAgent.enabled is true but bootstrap.snapshot.enabled is false, so no policy or JWT role would be created for it and every snapshot would fail with a 403." }}
  {{- end }}
  {{- if not (or $snap.s3.credentialsSecret $snap.s3.baoSecretPath) }}
{{- fail "openbao-platform: snapshotAgent is enabled but has no S3 credentials. Set snapshotAgent.s3.credentialsSecret, or s3.baoSecretPath to read them from OpenBao." }}
  {{- end }}
  {{- if not $snap.s3.uri }}
{{- fail "openbao-platform: snapshotAgent is enabled but s3.uri is empty; snapshots would be taken and then uploaded nowhere." }}
  {{- end }}
  {{- if not (has $snap.concurrencyPolicy (list "Forbid" "Replace" "Allow")) }}
{{- fail "openbao-platform: snapshotAgent.concurrencyPolicy must be Forbid, Replace or Allow." }}
  {{- end }}
  {{- if eq $snap.concurrencyPolicy "Allow" }}
{{- fail "openbao-platform: snapshotAgent.concurrencyPolicy is Allow, which lets a snapshot whose upload overruns the schedule run beside the next one against the same node. Use Forbid unless you have a specific reason not to." }}
  {{- end }}
{{- end }}

{{/* --- audit ---------------------------------------------------------------- */}}
{{- $ad := ($server.auditDevices) | default dict }}
{{- if and (($ad.file).enabled) (not (($server.auditStorage).enabled)) }}
{{- fail "openbao-platform: openbao.server.auditDevices.file is enabled but openbao.server.auditStorage.enabled is false, so nothing is mounted at the audit path. OpenBao would fail to start: a declared audit device that cannot be created aborts startup." }}
{{- end }}
{{- if and (not (($ad.file).enabled)) (($ad.http).enabled) }}
{{- fail "openbao-platform: the http audit device would be the only one declared. It is synchronous and does not retry, so an audit proxy outage would stop OpenBao serving requests entirely. Keep openbao.server.auditDevices.file.enabled=true." }}
{{- end }}
{{- if and (($ad.http).enabled) (not .Values.auditProxy.enabled) }}
{{- fail "openbao-platform: openbao.server.auditDevices.http is enabled but auditProxy.enabled is false. The device is declared in the config file, so OpenBao creates it at startup and will not start if the endpoint does not exist. Enable the proxy, or disable the device." }}
{{- end }}
{{- if and .Values.auditProxy.enabled (($ad.http).enabled) }}
  {{- if ne (int ($ad.http).port) (int .Values.auditProxy.listen.port) }}
{{- fail (printf "openbao-platform: openbao.server.auditDevices.http.port is %v but auditProxy.listen.port is %v. Audit records would be posted to a closed port and OpenBao would fail to start." ($ad.http).port .Values.auditProxy.listen.port) }}
  {{- end }}
  {{- if ne (($ad.http).uriPath | toString) (.Values.auditProxy.listen.tag | toString) }}
{{- fail (printf "openbao-platform: openbao.server.auditDevices.http.uriPath is %q but auditProxy.listen.tag is %q. Fluent Bit derives its tag from the URI path, so a mismatch means records arrive under a tag no OUTPUT matches and are silently dropped." ($ad.http).uriPath .Values.auditProxy.listen.tag) }}
  {{- end }}
{{- end }}
{{- if .Values.auditProxy.enabled }}
  {{- $o := .Values.auditProxy.output -}}
  {{- if and (eq $o.type "forward") (not $o.forward.host) }}
{{- fail "openbao-platform: auditProxy.output.type is 'forward' but auditProxy.output.forward.host is empty." }}
  {{- end }}
  {{- if and (eq $o.type "http") (not $o.http.host) }}
{{- fail "openbao-platform: auditProxy.output.type is 'http' but auditProxy.output.http.host is empty." }}
  {{- end }}
{{- end }}

{{/* --- restore needs a token that will still exist --------------------------- */}}
{{- if and .Values.restore.enabled (not .Values.restore.tokenSecret.name) .Values.bootstrap.revokeRootToken }}
{{- fail "openbao-platform: the restore Job defaults to the root-token in the init Secret, but bootstrap.revokeRootToken is true so that entry has been deleted. Regenerate a token with `bao operator generate-root` (using the unseal keys), put it in a Secret, and set restore.tokenSecret.name." }}
{{- end }}

{{/* --- ingress / route ------------------------------------------------------ */}}
{{- if and .Values.ingress.enabled .Values.route.enabled }}
{{- fail "openbao-platform: enable at most one of ingress.enabled and route.enabled." }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.host) }}
{{- fail "openbao-platform: ingress.enabled is true but ingress.host is empty." }}
{{- end }}
{{- if and (or .Values.ingress.enabled .Values.route.enabled) (not .Values.tls.server.enabled) }}
{{- fail "openbao-platform: external access is enabled but tls.server.enabled is false. Ingress and Route both target the frontend listener, which would not exist. Enable the frontend, or expose the backend listener deliberately by editing this check out." }}
{{- end }}
{{- if .Values.tls.server.enabled }}
  {{- $names := .Values.tls.server.dnsNames | default list -}}
  {{- if .Values.ingress.enabled }}
    {{- if not (has .Values.ingress.host $names) }}
{{- fail (printf "openbao-platform: ingress.host %q is not in tls.server.dnsNames %v, so the frontend certificate would not be valid for it." .Values.ingress.host $names) }}
    {{- end }}
  {{- end }}
  {{- if and .Values.route.enabled .Values.route.host }}
    {{- if not (has .Values.route.host $names) }}
{{- fail (printf "openbao-platform: route.host %q is not in tls.server.dnsNames %v." .Values.route.host $names) }}
    {{- end }}
  {{- end }}
  {{- if and (empty $names) (not .Values.tls.server.ipAddresses) }}
{{- fail "openbao-platform: tls.server.enabled is true but tls.server.dnsNames is empty; cert-manager cannot issue a certificate with no subject." }}
  {{- end }}
{{- end }}

{{/* --- issuer separation ----------------------------------------------------- */}}
{{- if and .Values.tls.server.enabled .Values.tls.internal.issuerRef.name }}
  {{- if and (eq .Values.tls.internal.issuerRef.name .Values.tls.server.issuerRef.name) (eq .Values.tls.internal.issuerRef.kind .Values.tls.server.issuerRef.kind) }}
{{- fail "openbao-platform: the backend and frontend certificates are configured to use the SAME issuer, which defeats the trust separation this chart exists to provide. Point tls.server.issuerRef at a different CA, or set tls.server.enabled=false and accept a single trust domain deliberately." }}
  {{- end }}
{{- end }}
{{- if and .Values.tls.server.enabled (not .Values.tls.server.issuerRef.name) }}
{{- fail "openbao-platform: tls.server.enabled is true but tls.server.issuerRef.name is empty. The frontend must be issued by an issuer you nominate — it deliberately does not fall back to the backend CA." }}
{{- end }}

{{/* --- TLS reload -------------------------------------------------------------- */}}
{{- $tr := ($server.tlsReload) | default dict }}
{{- $method := $tr.method | default "sighup" }}
{{- if not (has $method (list "sighup" "auto")) }}
{{- fail (printf "openbao-platform: openbao.server.tlsReload.method is %q; supported values are \"sighup\" and \"auto\"." $method) }}
{{- end }}
{{- if eq $method "auto" }}
    {{- $tag := ($server.image).tag | default (trimPrefix "v" $.Chart.AppVersion) }}
    {{- if or (hasPrefix "2.6." $tag) (hasPrefix "2.5." $tag) (hasPrefix "2.4." $tag) }}
{{- fail (printf "openbao-platform: tlsReload.method is \"auto\" but the server image tag is %q. tls_auto_reload does not exist in that release (PR #3530 landed on main after v2.6.2). OpenBao would only log `unknown or unsupported field tls_auto_reload` and carry on serving the stale certificate — the option looks applied and silently is not. Use method \"sighup\" until you are on a build that has it, and confirm by checking that warning is absent from the server log." $tag) }}
    {{- end }}
{{- end }}
{{- if .Values.tls.enabled }}
  {{- $hasSidecar := false }}
  {{- range ($server.extraContainers) | default list }}
    {{- if eq (.name | default "") "cert-reloader" }}{{ $hasSidecar = true }}{{ end }}
  {{- end }}
  {{- if and (eq $method "sighup") (not $hasSidecar) }}
{{- fail "openbao-platform: tlsReload.method is \"sighup\" but openbao.server.extraContainers has no `cert-reloader`. Nothing would reload the certificate after cert-manager renews it, and OpenBao would quietly keep serving the expired one." }}
  {{- end }}
  {{- if and (eq $method "sighup") (not $server.shareProcessNamespace) }}
{{- fail "openbao-platform: tlsReload.method is \"sighup\" but openbao.server.shareProcessNamespace is false, so the sidecar cannot see or signal the bao process." }}
  {{- end }}
  {{- if and (eq $method "auto") $hasSidecar }}
{{- fail "openbao-platform: tlsReload.method is \"auto\" but the `cert-reloader` sidecar is still in openbao.server.extraContainers. Remove it — otherwise you are paying for a container that duplicates what the listener now does." }}
  {{- end }}
{{- end }}

{{/* --- auto-unseal ------------------------------------------------------------ */}}
{{- $seal := ($server.seal) | default dict }}
{{- if $seal.type }}
  {{- if not (has $seal.type (list "azurekeyvault" "transit")) }}
{{- fail (printf "openbao-platform: openbao.server.seal.type is %q; supported values are \"azurekeyvault\" and \"transit\" (or \"\" for Shamir)." $seal.type) }}
  {{- end }}
  {{- if not .Values.bootstrap.init.autoUnseal }}
{{- fail (printf "openbao-platform: a %q seal is configured but bootstrap.init.autoUnseal is false. The Job would ask `operator init` for unseal keys when an auto-unsealing cluster issues RECOVERY keys, then sit trying to unseal a cluster that unseals itself. Set bootstrap.init.autoUnseal=true." $seal.type) }}
  {{- end }}
  {{- if eq $seal.type "azurekeyvault" }}
    {{- if not ($seal.azurekeyvault).vaultName }}
{{- fail "openbao-platform: seal.type is azurekeyvault but seal.azurekeyvault.vaultName is empty." }}
    {{- end }}
    {{- if not ($seal.azurekeyvault).keyName }}
{{- fail "openbao-platform: seal.type is azurekeyvault but seal.azurekeyvault.keyName is empty." }}
    {{- end }}
    {{- if eq (($seal.azurekeyvault).authMethod | default "") "workload_identity" }}
      {{- $saAnn := (($server.serviceAccount).annotations) | default dict }}
      {{- if not (index $saAnn "azure.workload.identity/client-id") }}
{{- fail "openbao-platform: azurekeyvault auth_method is workload_identity, but openbao.server.serviceAccount.annotations has no `azure.workload.identity/client-id`. Without it the azure-workload-identity webhook injects nothing and the seal fails at startup with a credential error. See values-azure.yaml." }}
      {{- end }}
      {{- $lbl := ($server.extraLabels) | default dict }}
      {{- if ne (index $lbl "azure.workload.identity/use" | toString) "true" }}
{{- fail "openbao-platform: azurekeyvault auth_method is workload_identity, but openbao.server.extraLabels does not set `azure.workload.identity/use: \"true\"`. The webhook only mutates pods carrying that label, so AZURE_FEDERATED_TOKEN_FILE is never injected." }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if eq $seal.type "transit" }}
    {{- if not ($seal.transit).address }}
{{- fail "openbao-platform: seal.type is transit but seal.transit.address is empty." }}
    {{- end }}
  {{- end }}
  {{/* plugin registration */}}
  {{- if ($seal.plugin).enabled }}
    {{- if ne $seal.plugin.name $seal.type }}
{{- fail (printf "openbao-platform: seal.plugin.name is %q but seal.type is %q. A plugin only shadows the built-in of the SAME name; mismatched, the seal stanza would resolve to the built-in (removed in v2.7.0) and the plugin would go unused." $seal.plugin.name $seal.type) }}
    {{- end }}
    {{- if not $seal.plugin.sha256sum }}
{{- fail "openbao-platform: seal.plugin.enabled is true but seal.plugin.sha256sum is empty. OpenBao verifies the binary against it — it is the whole reason fetching from a mirror or Artifactory is safe. Take it from checksums-kms-<provider>.txt on the plugin release." }}
    {{- end }}
    {{- if and (eq ($seal.plugin.source | default "preloaded") "oci") (not $seal.plugin.image) }}
{{- fail "openbao-platform: seal.plugin.source is \"oci\" but seal.plugin.image is empty." }}
    {{- end }}
    {{- if not (has ($seal.plugin.source | default "preloaded") (list "oci" "preloaded")) }}
{{- fail (printf "openbao-platform: seal.plugin.source is %q; supported values are \"oci\" and \"preloaded\"." $seal.plugin.source) }}
    {{- end }}
    {{/* the plugin directory has to actually exist in the pod */}}
    {{- $mounts := ($server.volumeMounts) | default list }}
    {{- $dirOk := false }}
    {{- range $mounts }}{{- if eq (.mountPath | default "") $seal.directory }}{{- $dirOk = true }}{{- end }}{{- end }}
    {{- if not $dirOk }}
{{- fail (printf "openbao-platform: no entry in openbao.server.volumeMounts mounts the plugin directory %q. OpenBao needs a real, writable, non-symlink directory there — an emptyDir is enough. See values-azure.yaml." $seal.directory) }}
    {{- end }}
  {{- end }}
{{- else if .Values.bootstrap.init.autoUnseal }}
{{- fail "openbao-platform: bootstrap.init.autoUnseal is true but no seal is configured (openbao.server.seal.type is empty). The Job would request recovery keys from a Shamir cluster and never unseal it. Configure a seal, or set autoUnseal=false." }}
{{- end }}

{{/* --- raft quorum ----------------------------------------------------------- */}}
{{- if eq ($ha.enabled | toString) "true" }}
  {{- $r := int ($ha.replicas | default 3) }}
  {{- if and (gt $r 1) (eq (mod $r 2) 0) }}
{{- fail (printf "openbao-platform: openbao.server.ha.replicas is %d. An even raft cluster size gives no extra fault tolerance over %d and doubles the chance of a lost quorum. Use an odd number." $r (sub $r 1)) }}
  {{- end }}
{{- end }}

{{- end -}}
