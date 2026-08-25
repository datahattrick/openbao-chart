{{/*
Naming.

The subchart derives every resource name from `openbao.fullname`, which is
`.Release.Name` when the release name already contains the chart name
("openbao"), otherwise "<release>-openbao". We MUST reproduce that logic here
verbatim, because our Certificates, NetworkPolicies and bootstrap Job all have
to line up with Services and StatefulSets the subchart created. Get this wrong
and the chart renders fine but nothing connects.
*/}}
{{- define "obp.baoFullname" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- if $bao.fullnameOverride -}}
{{- $bao.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "openbao" $bao.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Headless service the StatefulSet uses for stable per-pod DNS. */}}
{{- define "obp.baoHeadless" -}}
{{- printf "%s-internal" (include "obp.baoFullname" .) -}}
{{- end -}}

{{/* Namespace, honouring the subchart's global.namespace override. */}}
{{- define "obp.namespace" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- $global := $bao.global | default dict -}}
{{- default .Release.Namespace $global.namespace -}}
{{- end -}}

{{- define "obp.clusterDomain" -}}
{{- .Values.clusterDomain | default "cluster.local" -}}
{{- end -}}

{{- define "obp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "obp.labels" -}}
helm.sh/chart: {{ include "obp.chart" . }}
app.kubernetes.io/name: openbao
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openbao-platform
{{- end -}}

{{/* Replica count of the OpenBao StatefulSet, mirroring `openbao.replicas`. */}}
{{- define "obp.replicas" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- $server := $bao.server | default dict -}}
{{- $ha := $server.ha | default dict -}}
{{- if eq ($ha.enabled | toString) "true" -}}
{{- $ha.replicas | default 3 -}}
{{- else -}}
1
{{- end -}}
{{- end -}}

{{/* Effective server log level, needed by the key-reveal gate below. */}}
{{- define "obp.logLevel" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- $server := $bao.server | default dict -}}
{{- $server.logLevel | default "" | lower -}}
{{- end -}}

{{/*
The key-reveal gate.

Recovery/unseal keys and the root token are printed to the bootstrap Job's log
ONLY when all three hold:
  1. deployment.environment == "development"
  2. the OpenBao server log level is "debug" (or noisier)
  3. bootstrap.keyOutput.revealWhenDebug is left on

Anything else and the keys go to the Secret and nowhere else. Job logs are
readable by anyone with `pods/log` in the namespace and are shipped to the log
collector, so this is deliberately hard to switch on by accident.
*/}}
{{- define "obp.revealKeys" -}}
{{- $env := .Values.deployment.environment | default "production" | lower -}}
{{- $level := include "obp.logLevel" . -}}
{{- $noisy := has $level (list "debug" "trace") -}}
{{- if and (eq $env "development") $noisy .Values.bootstrap.keyOutput.revealWhenDebug -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Is TLS on? Single source of truth: the subchart's own `global.tlsDisable`, which
Helm propagates to every layer, so there is nothing to keep in sync.

Returns "true" or the empty string, so it reads directly as a gate:
  {{- if include "obp.tlsEnabled" . }}
*/}}
{{- define "obp.tlsEnabled" -}}
{{- if eq ((.Values.global).tlsDisable | toString) "true" -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/* Secret holding the unseal/recovery keys and the initial root token. */}}
{{- define "obp.initKeysSecret" -}}
{{- .Values.bootstrap.keyOutput.secretName | default (printf "%s-init-keys" (include "obp.baoFullname" .)) -}}
{{- end -}}

{{/* Secret cert-manager writes the backend (raft/internal) leaf into. */}}
{{- define "obp.internalTlsSecret" -}}
{{- .Values.tls.internal.secretName | default (printf "%s-tls-internal" (include "obp.baoFullname" .)) -}}
{{- end -}}

{{/* Secret cert-manager writes the frontend (webserver) leaf into. */}}
{{- define "obp.serverTlsSecret" -}}
{{- .Values.tls.server.secretName | default (printf "%s-tls-server" (include "obp.baoFullname" .)) -}}
{{- end -}}

{{/* Secret holding the namespace-local backend CA (key + cert). */}}
{{- define "obp.caSecret" -}}
{{- .Values.tls.ca.secretName | default (printf "%s-backend-ca" (include "obp.baoFullname" .)) -}}
{{- end -}}

{{/*
issuerRef for the backend leaf. Defaults to the CA Issuer this chart creates,
but can be pointed at an existing (Cluster)Issuer for shops that already run a
backend PKI.
*/}}
{{- define "obp.internalIssuerRef" -}}
{{- if .Values.tls.internal.issuerRef.name -}}
{{- toYaml .Values.tls.internal.issuerRef -}}
{{- else -}}
name: {{ include "obp.baoFullname" . }}-backend-ca
kind: Issuer
group: cert-manager.io
{{- end -}}
{{- end -}}

{{/* In-cluster address of the backend listener on the active node. */}}
{{- define "obp.baoInternalAddr" -}}
{{- $bao := index .Values "openbao" | default dict -}}
{{- $server := $bao.server | default dict -}}
{{- $ha := $server.ha | default dict -}}
{{- $svc := include "obp.baoFullname" . -}}
{{- if eq ($ha.enabled | toString) "true" -}}
{{- $svc = printf "%s-active" $svc -}}
{{- end -}}
{{- printf "https://%s.%s.svc.%s:%v" $svc (include "obp.namespace" .) (include "obp.clusterDomain" .) .Values.tls.internal.port -}}
{{- end -}}

{{/* Path the backend CA bundle is mounted at inside every pod we control. */}}
{{- define "obp.internalCaPath" -}}
{{- printf "%s/ca.crt" .Values.tls.internal.mountPath -}}
{{- end -}}

{{/*
Resolve a component's priority class: the component's own setting wins,
otherwise the chart-wide default. Emits nothing when neither is set, so the
field is simply absent rather than an empty string (which the API rejects).

Usage: {{- include "obp.priorityClassName" (dict "root" $ "component" .Values.bootstrap) }}
*/}}
{{- define "obp.priorityClassName" -}}
{{- $pc := "" -}}
{{- if .component -}}{{- $pc = .component.priorityClassName | default "" -}}{{- end -}}
{{- if not $pc -}}{{- $pc = .root.Values.priorityClassName | default "" -}}{{- end -}}
{{- if $pc }}
priorityClassName: {{ $pc }}
{{- end }}
{{- end -}}

{{/*
Pod-level securityContext for every workload this chart owns.

OpenShift hands out the uid, gid and fsGroup from the namespace's SCC range and
REJECTS a pod that pins them to anything outside it, so the ids are emitted only
when global.openshift is false. The rest (runAsNonRoot, seccompProfile) is
accepted by both restricted-v2 and Pod Security `restricted`, so it is always
emitted and the default renders cleanly on either platform.

Why a global and not a per-component map: `global.openshift` is a scalar, so it
merges predictably no matter how deeply this chart is nested, and it reaches the
openbao subchart without being restated. Clearing a MAP from a parent values
file does not work — Helm coalesces maps key by key, so `securityContext: {}`
leaves every inherited key in place. That is the bug this replaced.

Usage: {{- include "obp.podSecurityContext" (dict "root" $ "uid" 100 "gid" 1000) | nindent 6 }}
*/}}
{{- define "obp.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  {{- if not (.root.Values.global).openshift }}
  runAsUser: {{ .uid }}
  runAsGroup: {{ .gid }}
  fsGroup: {{ .gid }}
  {{- end }}
{{- end -}}
