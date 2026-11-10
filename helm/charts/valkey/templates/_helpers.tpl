{{/* 이름 = 릴리스 이름 (valkey-cache) → Service DNS · NetworkPolicy 라벨 */}}
{{- define "valkey.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "valkey.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "valkey.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: baedalsak
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "valkey.image" -}}
{{- $parts := list }}
{{- with .Values.image.registry }}{{ $parts = append $parts . }}{{ end }}
{{- with .Values.image.namespace }}{{ $parts = append $parts . }}{{ end }}
{{- $parts = append $parts "valkey" }}
{{- printf "%s:%s" (join "/" $parts) .Values.image.tag }}
{{- end }}
