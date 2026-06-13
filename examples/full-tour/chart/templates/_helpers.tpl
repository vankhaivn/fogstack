{{- define "full-tour.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "full-tour.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "full-tour.namespace" -}}
{{- default .Release.Namespace .Values.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "full-tour.labels" -}}
app.kubernetes.io/name: {{ include "full-tour.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: fogstack
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "full-tour.selectorLabels" -}}
app.kubernetes.io/name: {{ include "full-tour.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "full-tour.awsEndpointUrl" -}}
{{- if .Values.aws.endpointUrl -}}
{{- .Values.aws.endpointUrl -}}
{{- else -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" .Values.externalServices.awsApi.name (include "full-tour.namespace" .) .Values.externalServices.awsApi.port -}}
{{- end -}}
{{- end -}}

{{- define "full-tour.opensearchUrl" -}}
{{- if .Values.opensearch.url -}}
{{- .Values.opensearch.url -}}
{{- else -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" .Values.externalServices.opensearch.name (include "full-tour.namespace" .) .Values.externalServices.opensearch.port -}}
{{- end -}}
{{- end -}}
