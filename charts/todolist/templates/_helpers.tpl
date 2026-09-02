{{- define "todolist.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "todolist.fullname" -}}
{{- printf "%s" (include "todolist.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "todolist.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "todolist.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "todolist.selectorLabels" -}}
app.kubernetes.io/name: {{ include "todolist.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Referencia da imagem. Prefere o digest quando presente: um digest identifica o
conteudo exato e nao pode ser reescrito, ao contrario de uma tag.
*/}}
{{- define "todolist.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}

{{- define "todolist.dbCluster" -}}
{{ include "todolist.fullname" . }}-pg
{{- end -}}
