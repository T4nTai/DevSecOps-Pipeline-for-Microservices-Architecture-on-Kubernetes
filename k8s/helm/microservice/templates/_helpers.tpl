{{/*
Build the full image reference. When image.harborImage=true and global.harborRegistry
is set, prepend the registry to the repository path (e.g. "library/frontend").
Otherwise use image.repository as-is (for public images like gcr.io/...).
*/}}
{{- define "microservice.fullImage" -}}
{{- if and .Values.image.harborImage .Values.global.harborRegistry -}}
{{ .Values.global.harborRegistry }}/{{ .Values.image.repository }}
{{- else -}}
{{ .Values.image.repository }}
{{- end -}}
{{- end -}}

{{/*
Render the health probe block based on probe.type.
Used in both readinessProbe and livenessProbe.
*/}}
{{- define "microservice.probe" -}}
{{- if eq .Values.probe.type "grpc" }}
grpc:
  port: {{ .Values.port.container }}
{{- else if eq .Values.probe.type "http" }}
httpGet:
  path: {{ .Values.probe.path }}
  port: {{ .Values.port.container }}
{{- else if eq .Values.probe.type "tcp" }}
tcpSocket:
  port: {{ .Values.port.container }}
{{- end }}
{{- end }}
