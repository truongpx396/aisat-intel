{{/*
Chart name (respecting nameOverride).
*/}}
{{- define "aisat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully-qualified release name. Used for singleton objects (ConfigMaps, Secret,
Ingress, ServiceAccount). Per-workload objects instead use the bare component
key as their name so in-cluster DNS matches the compose service names
(e.g. `redis`, `go-api`) that the Caddyfile and config URLs depend on.
*/}}
{{- define "aisat.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "aisat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels (no component). Add `app.kubernetes.io/component` at the call site.
*/}}
{{- define "aisat.labels" -}}
helm.sh/chart: {{ include "aisat.chart" . }}
app.kubernetes.io/name: {{ include "aisat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels for a single workload. Call with (dict "root" $ "name" "<key>").
*/}}
{{- define "aisat.selectorLabels" -}}
{{- $root := .root -}}
app.kubernetes.io/name: {{ include "aisat.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{- define "aisat.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "aisat.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "aisat.configName" -}}
{{- printf "%s-config" (include "aisat.fullname" .) -}}
{{- end -}}

{{/*
Name of the Secret the app pods read via envFrom. An existingSecret wins;
otherwise the chart-managed (or ExternalSecrets-managed) `<fullname>-secrets`.
*/}}
{{- define "aisat.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "aisat.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve a component's image ref. Call with (dict "root" $ "comp" $c).
imageOverride pins a public image verbatim; otherwise build from the shared
registry/prefix + the component's repo + tag.
*/}}
{{- define "aisat.componentImage" -}}
{{- $root := .root -}}
{{- $c := .comp -}}
{{- if $c.imageOverride -}}
{{- $c.imageOverride -}}
{{- else -}}
{{- printf "%s/%s-%s:%s" $root.Values.image.registry $root.Values.image.prefix $c.repo ($root.Values.image.tag | toString) -}}
{{- end -}}
{{- end -}}
