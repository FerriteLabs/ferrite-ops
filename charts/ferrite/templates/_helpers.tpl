{{/*
Expand the name of the chart.
*/}}
{{- define "ferrite.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ferrite.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ferrite.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ferrite.labels" -}}
helm.sh/chart: {{ include "ferrite.chart" . }}
{{ include "ferrite.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ferrite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ferrite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ferrite.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ferrite.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "ferrite.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Return whether TLS is enabled (top-level or ferrite.tls)
*/}}
{{- define "ferrite.tlsEnabled" -}}
{{- or .Values.tls.enabled .Values.ferrite.tls.enabled }}
{{- end }}

{{/*
Return the TLS secret name based on configuration priority:
1. tls.existingSecret
2. ferrite.tls.secretName (backward compat)
3. Generated name (used by tls-secret.yaml and certificate.yaml)
*/}}
{{- define "ferrite.tlsSecretName" -}}
{{- if .Values.tls.existingSecret }}
{{- .Values.tls.existingSecret }}
{{- else if .Values.ferrite.tls.secretName }}
{{- .Values.ferrite.tls.secretName }}
{{- else }}
{{- include "ferrite.fullname" . }}-tls
{{- end }}
{{- end }}

{{/*
Return the ferrite configuration
*/}}
{{- define "ferrite.config" -}}
[server]
bind = {{ .Values.ferrite.server.bind | quote }}
port = 6379
max_connections = {{ .Values.ferrite.server.maxConnections }}
tcp_keepalive = {{ .Values.ferrite.server.tcpKeepalive }}
timeout = {{ .Values.ferrite.server.timeout }}
proto_max_bulk_len = {{ .Values.ferrite.server.protoMaxBulkLen }}
proto_max_multi_bulk_len = {{ .Values.ferrite.server.protoMaxMultiBulkLen }}
proto_max_nesting_depth = {{ .Values.ferrite.server.protoMaxNestingDepth }}

[storage]
databases = {{ .Values.ferrite.storage.databases }}
max_memory = {{ .Values.ferrite.storage.maxMemory }}
backend = {{ .Values.ferrite.storage.backend | quote }}
data_dir = "/var/lib/ferrite/data"
max_key_size = {{ .Values.ferrite.storage.maxKeySize }}
max_value_size = {{ .Values.ferrite.storage.maxValueSize }}

[persistence]
aof_enabled = {{ .Values.ferrite.persistence.aofEnabled }}
aof_path = "/var/lib/ferrite/data/{{ .Values.ferrite.persistence.aofPath }}"
aof_sync = {{ .Values.ferrite.persistence.aofSync | quote }}
checkpoint_enabled = {{ .Values.ferrite.persistence.checkpointEnabled }}
checkpoint_interval = {{ .Values.ferrite.persistence.checkpointInterval | quote }}
checkpoint_path = "/var/lib/ferrite/data/{{ .Values.ferrite.persistence.checkpointDir }}"

[logging]
level = {{ .Values.ferrite.logging.level | quote }}
format = {{ .Values.ferrite.logging.format | quote }}
{{- if .Values.ferrite.logging.file }}
file = {{ .Values.ferrite.logging.file | quote }}
{{- end }}

[metrics]
enabled = {{ .Values.ferrite.metrics.enabled }}
port = 9090
path = {{ .Values.ferrite.metrics.path | quote }}
{{- if or .Values.tls.enabled .Values.ferrite.tls.enabled }}

[tls]
enabled = true
port = {{ .Values.ferrite.tls.port }}
cert_file = "/etc/ferrite/tls/tls.crt"
key_file = "/etc/ferrite/tls/tls.key"
{{- if or .Values.tls.clientCA .Values.ferrite.tls.requireClientCert }}
ca_file = "/etc/ferrite/tls/ca.crt"
require_client_cert = true
{{- end }}
{{- end }}
{{- if .Values.cluster.enabled }}

[cluster]
enabled = true
port = {{ .Values.cluster.port }}
{{- end }}
{{- if .Values.replication.enabled }}

[replication]
role = {{ .Values.replication.role | quote }}
{{- if eq .Values.replication.role "replica" }}
primary_host = {{ .Values.replication.primaryHost | quote }}
primary_port = {{ .Values.replication.primaryPort }}
{{- end }}
{{- end }}
{{- end }}
