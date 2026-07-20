{{/*
Render OpenTelemetry env vars for one MCM process. When tracing is disabled,
this helper emits no OTEL_* variables, leaving tracing off in the runtime.
*/}}
{{- define "radar.otelEnv" -}}
{{- $otel := .ctx.Values.opentelemetry -}}
{{- if $otel.enabled -}}
{{- $endpoint := required "opentelemetry.endpoint is required when opentelemetry.enabled is true" $otel.endpoint -}}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $endpoint | quote }}
{{- $service := .defaultService -}}
{{- if .serviceOverride -}}
{{- $service = .serviceOverride -}}
{{- end }}
- name: OTEL_SERVICE_NAME
  value: {{ $service | quote }}
{{- with $otel.sampler }}
{{- with .name }}
- name: OTEL_TRACES_SAMPLER
  value: {{ . | quote }}
{{- end }}
{{- with .arg }}
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- with $otel.resourceAttributes }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ . | quote }}
{{- end }}
{{- if and $otel.headersSecret.name $otel.headersSecret.key }}
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: {{ $otel.headersSecret.name | quote }}
      key: {{ $otel.headersSecret.key | quote }}
{{- end }}
{{- end -}}
{{- end -}}
