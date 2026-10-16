{{/* 서비스 이름 = 릴리스 이름 (gateway, store, ...) → Service DNS 이름 */}}
{{- define "svc.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "svc.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "svc.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | trunc 63 | quote }}
app.kubernetes.io/part-of: baedalsak
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* 이미지: image.repository 우선, 없으면 [<registry>/]<namespace>/<서비스> */}}
{{- define "svc.image" -}}
{{- $repo := .Values.image.repository }}
{{- if not $repo }}
{{- $parts := list }}
{{- with .Values.global.imageRegistry }}{{ $parts = append $parts . }}{{ end }}
{{- with .Values.global.imageNamespace }}{{ $parts = append $parts . }}{{ end }}
{{- $parts = append $parts (include "svc.name" .) }}
{{- $repo = join "/" $parts }}
{{- end }}
{{- printf "%s:%s" $repo (required "image.tag 값이 필요합니다 (--set image.tag=...)" .Values.image.tag) }}
{{- end }}

{{/* 비밀번호가 필요한 서비스인지 */}}
{{- define "svc.needsSecret" -}}
{{- if or .Values.db.enabled .Values.rabbitmq.enabled .Values.redisSession.enabled .Values.secretKeys }}true{{ end }}
{{- end }}

{{/* 비밀번호 Secret 이름: 운영(ExternalSecret)은 서비스별, 로컬은 공용 */}}
{{- define "svc.secretName" -}}
{{- if .Values.global.externalSecret.enabled }}
{{- include "svc.name" . }}
{{- else }}
{{- required "global.secretName 값이 필요합니다 (로컬: make secret 으로 생성한 Secret 이름)" .Values.global.secretName }}
{{- end }}
{{- end }}

{{/* IRSA 역할 ARN */}}
{{- define "svc.roleArn" -}}
{{- if and .Values.serviceAccount.irsa .Values.global.irsaRoleArnFormat }}
{{- printf .Values.global.irsaRoleArnFormat (include "svc.name" .) }}
{{- end }}
{{- end }}

{{- define "svc.stripMiddlewareName" -}}
{{- printf "%s-strip-prefix" (include "svc.name" .) }}
{{- end }}

{{- define "svc.prefixHeaderMiddlewareName" -}}
{{- printf "%s-drop-prefix-header" (include "svc.name" .) }}
{{- end }}
