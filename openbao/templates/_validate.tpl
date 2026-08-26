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
{{/* global.tlsDisable is the only switch and both charts read it, so there is */}}
{{/* no pair left to cross-check. What still needs catching: turning TLS off   */}}
{{/* without replacing the raft HCL, whose listeners name certificate files    */}}
{{/* that pki.yaml then never issues.                                          */}}
{{- if not (include "obp.tlsEnabled" .) }}
  {{- if contains "tls_cert_file" ((($server.ha).raft).config | default "") }}
{{- fail "openbao-platform: global.tlsDisable is true, but openbao.server.ha.raft.config still declares tls_cert_file. No certificate is issued when TLS is off, so the server would fail to start. Replace the raft config with plaintext listeners, or set global.tlsDisable=false." }}
  {{- end }}
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
{{- if include "obp.tlsEnabled" . }}
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

{{/* --- OpenShift <-> pinned uids ------------------------------------------- */}}
{{- if (.Values.global).openshift }}
  {{- $sc := (($server.statefulSet).securityContext).pod }}
  {{- if $sc }}
    {{- if or (kindIs "string" $sc) (or $sc.runAsUser $sc.runAsGroup $sc.fsGroup) }}
{{- fail "openbao-platform: global.openshift is true but openbao.server.statefulSet.securityContext.pod is set. The SCC assigns uid/gid/fsGroup from the namespace's range and REJECTS a pod that pins them, and anything set here replaces the subchart's platform-aware default wholesale. Leave it empty ({}) and let global.openshift decide, or set global.openshift=false if this is not OpenShift. NOTE: clearing it from an overlay does not work — Helm coalesces maps key by key, so `pod: {}` in a second values file overrides nothing." }}
    {{- end }}
  {{- end }}
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
  {{- if ne ((($ad.http).tls | default false) | toString) ((.Values.auditProxy.tls.enabled | default false) | toString) }}
{{- fail (printf "openbao-platform: openbao.server.auditDevices.http.tls is %v but auditProxy.tls.enabled is %v. One side would speak plaintext to a TLS listener, the audit device would fail, and the bootstrap would refuse to initialise. Set both the same." (($ad.http).tls | default false) (.Values.auditProxy.tls.enabled | default false)) }}
  {{- end }}
  {{- if and (($ad.http).tls) (not (include "obp.tlsEnabled" .)) }}
{{- fail "openbao-platform: openbao.server.auditDevices.http.tls is true but global.tlsDisable is set, so there is no backend CA to issue the proxy a certificate or for OpenBao to verify it against. Turn the hop's TLS off too, or leave global.tlsDisable=false." }}
  {{- end }}
  {{/* The device has no CA option: it trusts whatever is in the process store,
       which for the backend CA means SSL_CERT_DIR. That variable REPLACES Go's
       default directory list, so appending a second entry and losing this one
       is a one-character mistake that breaks every audit write. */}}
  {{- if ($ad.http).tls }}
    {{- $certDir := (($server.extraEnvironmentVars).SSL_CERT_DIR) | default "" }}
    {{- if not (has .Values.tls.internal.mountPath (splitList ":" $certDir)) }}
{{- fail (printf "openbao-platform: the http audit device speaks TLS to the audit proxy, but openbao.server.extraEnvironmentVars.SSL_CERT_DIR is %q and does not list the backend CA's mount %q. The device takes no CA option, so OpenBao could not verify the proxy and every audit write would fail — which stops OpenBao serving requests. SSL_CERT_DIR is a colon-separated list and REPLACES Go's defaults, so keep this entry in it when you add others." $certDir .Values.tls.internal.mountPath) }}
    {{- end }}
  {{- end }}
  {{- if ne (int ($ad.http).port) (int .Values.auditProxy.listen.port) }}
{{- fail (printf "openbao-platform: openbao.server.auditDevices.http.port is %v but auditProxy.listen.port is %v. Audit records would be posted to a closed port and OpenBao would fail to start." ($ad.http).port .Values.auditProxy.listen.port) }}
  {{- end }}
  {{- if ne (($ad.http).uriPath | toString) (.Values.auditProxy.listen.path | toString) }}
{{- fail (printf "openbao-platform: openbao.server.auditDevices.http.uriPath is %q but auditProxy.listen.path is %q. The collector serves one URL path, so records would be POSTed to a 404 and the audit device would fail." ($ad.http).uriPath .Values.auditProxy.listen.path) }}
  {{- end }}
{{- end }}
{{- if .Values.auditProxy.enabled }}
  {{- $o := .Values.auditProxy.output -}}
  {{- if not (has $o.type (list "otlphttp" "otlp" "none")) }}
{{- fail (printf "openbao-platform: auditProxy.output.type is %q; it must be \"otlphttp\", \"otlp\" or \"none\"." $o.type) }}
  {{- end }}
  {{- if and (eq $o.type "otlphttp") (not $o.otlphttp.endpoint) }}
{{- fail "openbao-platform: auditProxy.output.type is 'otlphttp' but auditProxy.output.otlphttp.endpoint is empty. It is the FULL logs URL, e.g. http://vlogs.monitoring.svc:9428/insert/opentelemetry/v1/logs." }}
  {{- end }}
  {{- if and (eq $o.type "otlp") (not $o.otlp.endpoint) }}
{{- fail "openbao-platform: auditProxy.output.type is 'otlp' but auditProxy.output.otlp.endpoint is empty. It is a gRPC host:port." }}
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
{{/* --- certificate sources ------------------------------------------------ */}}
{{- $beSource := .Values.tls.internal.source | default "cert-manager" }}
{{- if not (has $beSource (list "cert-manager" "secret")) }}
{{- fail (printf "openbao-platform: tls.internal.source is %q; it must be \"cert-manager\" (this chart issues the backend certificate) or \"secret\" (you supply it)." $beSource) }}
{{- end }}
{{- if and (include "obp.tlsEnabled" .) (eq $beSource "secret") }}
  {{- if not .Values.tls.internal.secretName }}
{{- fail "openbao-platform: tls.internal.source is \"secret\" but tls.internal.secretName is empty. Name the Secret holding the backend certificate; it must carry ca.crt as well as tls.crt and tls.key, since raft joins validate peers against it." }}
  {{- end }}
  {{- if and .Values.auditProxy.enabled .Values.auditProxy.tls.enabled }}
{{- fail "openbao-platform: auditProxy.tls.enabled needs the backend Issuer to sign the proxy's certificate, and tls.internal.source is \"secret\", so this chart creates no Issuer. Issue that certificate yourself and set tls.internal.source=cert-manager, or turn the proxy's TLS off." }}
  {{- end }}
{{- end }}

{{/* --- Route termination ------------------------------------------------- */}}
{{- if .Values.route.enabled }}
  {{- if not (has .Values.route.termination (list "passthrough" "reencrypt")) }}
{{- fail (printf "openbao-platform: route.termination is %q. Only \"passthrough\" (OpenBao terminates) and \"reencrypt\" (the router terminates and opens a second TLS leg) work here — the frontend listener speaks TLS only, so \"edge\" would send it plaintext." .Values.route.termination) }}
  {{- end }}
  {{- if and (eq .Values.route.termination "reencrypt") (not .Values.route.destinationCACertificate) }}
{{- fail "openbao-platform: route.termination is \"reencrypt\" but route.destinationCACertificate is empty, so the router falls back to the service CA and cannot verify the frontend listener. Paste the frontend CA there, or use termination=passthrough and let OpenBao terminate." }}
  {{- end }}
{{- end }}

{{- $feSource := .Values.tls.server.source | default "cert-manager" }}
{{- if not (has $feSource (list "cert-manager" "secret")) }}
{{- fail (printf "openbao-platform: tls.server.source is %q; it must be \"cert-manager\" (this chart issues the frontend certificate) or \"secret\" (you supply it)." $feSource) }}
{{- end }}

{{/* The SAN checks below can only be made against a Certificate this chart
     writes. With source=secret the names live in someone else's Secret, so a
     wrong hostname surfaces as a client-side verification failure instead. */}}
{{- if and .Values.tls.server.enabled (eq $feSource "cert-manager") }}
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

{{- if and .Values.tls.server.enabled (eq $feSource "secret") (not .Values.tls.server.secretName) }}
{{- fail "openbao-platform: tls.server.source is \"secret\" but tls.server.secretName is empty. Name the kubernetes.io/tls Secret holding the frontend certificate; the chart mounts it rather than issuing one." }}
{{- end }}

{{/* --- issuer separation ----------------------------------------------------- */}}
{{- if and .Values.tls.server.enabled (eq $feSource "cert-manager") }}
  {{/* Resolve what the BACKEND leaf is actually issued by: either an issuer
       the operator nominated, or the CA this chart creates. Both have to be
       compared, or pointing the frontend at the chart-created CA slips through
       — which is the easiest version of this mistake to make. */}}
  {{- $beName := .Values.tls.internal.issuerRef.name | default (printf "%s-backend-ca" $fullname) }}
  {{- $beKind := "Issuer" }}
  {{- if .Values.tls.internal.issuerRef.name }}{{ $beKind = .Values.tls.internal.issuerRef.kind }}{{ end }}
  {{- if and (eq $beName .Values.tls.server.issuerRef.name) (eq $beKind .Values.tls.server.issuerRef.kind) }}
{{- fail (printf "openbao-platform: the frontend certificate is configured to use the SAME issuer as the backend (%s/%s), which defeats the trust separation this chart exists to provide — a certificate from that issuer would be valid for both the ingress and a raft peer. Point tls.server.issuerRef at a different CA, or set tls.server.enabled=false and accept a single trust domain deliberately." $beKind $beName) }}
  {{- end }}
  {{- if not .Values.tls.server.issuerRef.name }}
{{- fail "openbao-platform: tls.server.enabled is true but tls.server.issuerRef.name is empty. The frontend must be issued by an issuer you nominate — it deliberately does not fall back to the backend CA. Set tls.server.source=secret to supply the certificate yourself instead." }}
  {{- end }}
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
{{- if include "obp.tlsEnabled" . }}
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
    {{/* `version` is required in BOTH plugin forms, and for source=oci it is
         also the image tag — OpenBao builds the reference itself as
         image + ":" + version. */}}
    {{- if not $seal.plugin.version }}
{{- fail "openbao-platform: seal.plugin.enabled is true but seal.plugin.version is empty. It is a required field of the plugin stanza, and for source=oci it supplies the image tag — OpenBao joins image and version itself. Set it to the plugin release, e.g. \"v0.1.0\"." }}
    {{- end }}
    {{- if not (has ($seal.plugin.source | default "preloaded") (list "oci" "preloaded")) }}
{{- fail (printf "openbao-platform: seal.plugin.source is %q; supported values are \"oci\" and \"preloaded\"." $seal.plugin.source) }}
    {{- end }}
    {{- if eq ($seal.plugin.source | default "preloaded") "oci" }}
      {{- if not $seal.plugin.image }}
{{- fail "openbao-platform: seal.plugin.source is \"oci\" but seal.plugin.image is empty." }}
      {{- end }}
      {{/* The tag belongs in `version`. Only the LAST path segment can hold
           one — a colon earlier is a registry port, which is legitimate. */}}
      {{- $ref := last (splitList "/" $seal.plugin.image) }}
      {{- if or (contains ":" $ref) (contains "@" $ref) }}
{{- fail (printf "openbao-platform: seal.plugin.image is %q, but it must carry NO tag or digest — OpenBao builds the reference as image + \":\" + version, so a tag here makes it a second colon and the server fails to start with `image and version do not form a valid image reference`. Move the tag to seal.plugin.version." $seal.plugin.image) }}
      {{- end }}
      {{- if not $seal.autoDownload }}
{{- fail "openbao-platform: seal.plugin.source is \"oci\" but seal.autoDownload is false. `plugin_auto_download` defaults to FALSE in OpenBao, so the server would never contact the registry, nothing would land in the plugin directory, and the seal would fail as \"plugin not found\". Set seal.autoDownload=true, or use source=preloaded and fetch the binary with an initContainer." }}
      {{- end }}
      {{/* Private registry CA. The pull happens in the server process and has
           no CA option of its own, so the bundle has to be mounted AND named
           in SSL_CERT_DIR. Declaring the ConfigMap mounts nothing by itself —
           Helm cannot template subchart values — so all three are checked. */}}
      {{- $rca := ($seal.plugin.registryCA) | default dict }}
      {{- if $rca.configMap }}
        {{- $cmFound := false }}
        {{- range ($server.volumes | default list) }}
          {{- if eq ((.configMap).name | default "") $rca.configMap }}{{ $cmFound = true }}{{ end }}
        {{- end }}
        {{- if not $cmFound }}
{{- fail (printf "openbao-platform: seal.plugin.registryCA.configMap is %q but no entry in openbao.server.volumes mounts that ConfigMap. The image pull would fall back to public roots and fail with `x509: certificate signed by unknown authority`. Add the volume (and its volumeMount at %s)." $rca.configMap $rca.mountPath) }}
        {{- end }}
        {{- $mFound := false }}
        {{- range ($server.volumeMounts | default list) }}
          {{- if eq (.mountPath | default "") $rca.mountPath }}{{ $mFound = true }}{{ end }}
        {{- end }}
        {{- if not $mFound }}
{{- fail (printf "openbao-platform: no entry in openbao.server.volumeMounts mounts the registry CA at %q. The ConfigMap is declared and attached to the pod but never appears in the filesystem." $rca.mountPath) }}
        {{- end }}
        {{- $certDir := (($server.extraEnvironmentVars).SSL_CERT_DIR) | default "" }}
        {{- if not (has $rca.mountPath (splitList ":" $certDir)) }}
{{- fail (printf "openbao-platform: the registry CA is mounted at %q but openbao.server.extraEnvironmentVars.SSL_CERT_DIR is %q, which does not list it. Go reads only the directories named there, so the bundle would sit on disk untrusted. Make it a colon-separated list that includes BOTH the backend CA's mount and %s." $rca.mountPath $certDir $rca.mountPath) }}
        {{- end }}
      {{- end }}
    {{- end }}
    {{- if not (has ($seal.downloadBehavior | default "fail") (list "fail" "warn")) }}
{{- fail (printf "openbao-platform: seal.downloadBehavior is %q; it must be \"fail\" or \"warn\" (it renders plugin_download_behavior). Anything else is rejected by the server at startup." $seal.downloadBehavior) }}
    {{- end }}
    {{- if and (or $seal.plugin.args $seal.plugin.env) (not $seal.autoRegister) }}
{{- fail "openbao-platform: seal.plugin.args/env are set but seal.autoRegister is false. Those two fields are only applied when the plugin is auto-registered into the catalog, so as configured they would be written to the config file and silently ignored. Set seal.autoRegister=true, or drop the args/env." }}
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
