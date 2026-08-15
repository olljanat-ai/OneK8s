{{/*
Release-scoped names. The release name is "hello-<cloud>" when Argo CD applies
this chart, so the objects are already distinct per cluster; the truncation is
the usual guard against a long release name overrunning a DNS label.
*/}}
{{- define "hello.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "hello.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: onek8s
onek8s.io/cloud: {{ .Values.cloud | quote }}
onek8s.io/environment: {{ .Values.environment | quote }}
onek8s.io/tenant: {{ .Values.tenant | quote }}
{{- end -}}

{{- define "hello.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hello.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
The key the ExternalSecret asks the backend for, and the only thing in this
chart that is not the same string on every cloud.

Every tenant identity is restricted to a name prefix, and the prefix is not
spelled the same everywhere: Key Vault, Secret Manager, OCI Vault and
HashiCorp Vault use "<tenant>-", while Secrets Manager names are paths and the
IAM policy grants "<environment>/<tenant>/*". That difference is load-bearing
rather than cosmetic — Secrets Manager is account-wide, so the environment has
to be part of the name for two environments to share an account — and it is
contained here rather than pushed out into five sets of values.

The *shape* of the ExternalSecret is identical everywhere, because every
secret this platform stores is a JSON object of fields and the manifest
extracts one. Nothing about Vault's KV v2 leaks into it.

Asking for anything outside the prefix is not a mistake this chart can make
quietly: the read is refused outside Kubernetes — by cloud IAM, or by a Vault
policy — and the ExternalSecret goes SecretSyncedError.
*/}}
{{- define "hello.remoteKey" -}}
{{- if .Values.secret.remoteKey -}}
{{- .Values.secret.remoteKey -}}
{{- else if eq .Values.cloud "aws" -}}
{{- printf "%s/%s/%s" .Values.environment .Values.tenant .Values.secret.name -}}
{{- else -}}
{{- printf "%s-%s" .Values.tenant .Values.secret.name -}}
{{- end -}}
{{- end -}}

{{/*
Key inside the generated Kubernetes Secret, which is also the file name the app
reads under /etc/onek8s/secret — and, because the manifest extracts the whole
object, the name of the field inside the stored secret. The platform writes it:
see the Renew Certificate workflow, which publishes {"test": "…"}.
*/}}
{{- define "hello.secretKey" -}}
{{- .Values.secret.name -}}
{{- end -}}

{{- define "hello.secretName" -}}
{{- printf "%s-secret" (include "hello.fullname" .) -}}
{{- end -}}
