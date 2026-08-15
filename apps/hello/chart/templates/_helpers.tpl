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
The key the ExternalSecret asks the backend for.

Every cloud's tenant identity is restricted to a name prefix, and the prefix is
not spelled the same everywhere: Key Vault, Secret Manager and OCI Vault use
"<tenant>-", while Secrets Manager names are paths and the IAM policy grants
"<environment>/<tenant>/*". That difference is the only thing in this chart
that is not cloud-agnostic, and it is contained here rather than pushed out
into four sets of values.

Asking for anything outside the prefix is not a mistake this chart can make
quietly: the cloud IAM plane refuses the read and the ExternalSecret goes
SecretSyncedError.
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
The field to take out of that secret, or empty for "the whole value".

The four public clouds store a secret as an opaque value, so there is nothing
to select inside it. HashiCorp Vault's KV v2 has no such thing: every secret is
a map of fields, and asking for one without naming a field returns the whole
map as JSON. So on the private cloud the remote reference carries a property,
and the field it names is the same "test" the generated Kubernetes Secret uses
as its key — which keeps the value the page shows identical on all five.
*/}}
{{- define "hello.remoteProperty" -}}
{{- if .Values.secret.remoteProperty -}}
{{- .Values.secret.remoteProperty -}}
{{- else if eq .Values.cloud "nutanix" -}}
{{- .Values.secret.name -}}
{{- end -}}
{{- end -}}

{{/*
Key inside the generated Kubernetes Secret, which is also the file name the app
reads under /etc/onek8s/secret.
*/}}
{{- define "hello.secretKey" -}}
{{- .Values.secret.name -}}
{{- end -}}

{{- define "hello.secretName" -}}
{{- printf "%s-secret" (include "hello.fullname" .) -}}
{{- end -}}
