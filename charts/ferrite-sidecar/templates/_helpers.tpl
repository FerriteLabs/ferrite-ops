{{/*
Expand the name of the chart.
*/}}
{{- define "ferrite-sidecar.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "ferrite-sidecar.fullname" -}}
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
{{- define "ferrite-sidecar.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ferrite-sidecar.labels" -}}
helm.sh/chart: {{ include "ferrite-sidecar.chart" . }}
{{ include "ferrite-sidecar.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ferrite-sidecar.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ferrite-sidecar.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "ferrite-sidecar.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Webhook component name
*/}}
{{- define "ferrite-sidecar.webhook.fullname" -}}
{{- printf "%s-webhook" (include "ferrite-sidecar.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Webhook labels
*/}}
{{- define "ferrite-sidecar.webhook.labels" -}}
{{ include "ferrite-sidecar.labels" . }}
app.kubernetes.io/component: webhook
{{- end }}

{{/*
Webhook selector labels
*/}}
{{- define "ferrite-sidecar.webhook.selectorLabels" -}}
{{ include "ferrite-sidecar.selectorLabels" . }}
app.kubernetes.io/component: webhook
{{- end }}

{{/*
Webhook service account name
*/}}
{{- define "ferrite-sidecar.webhook.serviceAccountName" -}}
{{- printf "%s-webhook" (include "ferrite-sidecar.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Webhook TLS secret name
*/}}
{{- define "ferrite-sidecar.webhook.tlsSecretName" -}}
{{- printf "%s-webhook-tls" (include "ferrite-sidecar.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Return the proper injector image name
*/}}
{{- define "ferrite-sidecar.injector.image" -}}
{{- printf "%s:%s" .Values.injector.image.repository .Values.injector.image.tag }}
{{- end }}

{{/*
Return the proper sidecar image name (for the injected container)
*/}}
{{- define "ferrite-sidecar.sidecar.image" -}}
{{- printf "%s:%s" .Values.sidecar.image.repository .Values.sidecar.image.tag }}
{{- end }}
