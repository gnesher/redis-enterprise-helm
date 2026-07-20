{{/*
Expand the name of the chart.
*/}}
{{- define "radar.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If the release name already contains the chart name it is used as the full name.
*/}}
{{- define "radar.fullname" -}}
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
Create chart label value.
*/}}
{{- define "radar.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "radar.labels" -}}
helm.sh/chart: {{ include "radar.chart" . }}
{{ include "radar.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. Used by Service selectors and Deployment pod selectors.
The component label is appended per-resource to distinguish app from worker.
*/}}
{{- define "radar.selectorLabels" -}}
app.kubernetes.io/name: {{ include "radar.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "radar.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "radar.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
ServiceAccount used by the API deployment.
*/}}
{{- define "radar.apiServiceAccountName" -}}
{{- include "radar.serviceAccountName" . }}
{{- end }}

{{/*
ServiceAccount used by the worker deployment.
*/}}
{{- define "radar.workerServiceAccountName" -}}
{{- include "radar.serviceAccountName" . }}
{{- end }}

{{/*
Runtime pod ServiceAccount token automount.
GKE Workload Identity needs the projected Kubernetes ServiceAccount token.
API/worker pods only override automount when the runtime ServiceAccount carries
the WI annotation.
*/}}
{{- define "radar.runtimeAutomountServiceAccountToken" -}}
{{- $annotations := .Values.serviceAccount.annotations | default dict -}}
{{- if index $annotations "iam.gke.io/gcp-service-account" -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
ServiceAccount used by the migration job.
*/}}
{{- define "radar.migrateServiceAccountName" -}}
{{- $migrate := .Values.serviceAccount.migrate | default dict -}}
{{- if $migrate.name }}
{{- $migrate.name }}
{{- else if .Values.serviceAccount.create }}
{{- "radar-flyway-migrator" }}
{{- else }}
{{- "default" }}
{{- end }}
{{- end }}

{{/*
Migrate ServiceAccount token automount.
GKE Workload Identity needs the projected Kubernetes ServiceAccount token.
Keep it disabled unless the migrate ServiceAccount carries the WI annotation.
*/}}
{{- define "radar.migrateAutomountServiceAccountToken" -}}
{{- $migrate := .Values.serviceAccount.migrate | default dict -}}
{{- $annotations := $migrate.annotations | default dict -}}
{{- if index $annotations "iam.gke.io/gcp-service-account" -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
Helm hook phases used by the migration job and its ServiceAccount.
*/}}
{{- define "radar.migrateHookPhases" -}}
{{- if .Values.postgresql.enabled -}}post-install,post-upgrade{{- else -}}pre-install,pre-upgrade{{- end -}}
{{- end }}

{{/*
Image pull secrets — merges global and chart-level lists.
*/}}
{{- define "radar.imagePullSecrets" -}}
{{- $global := .Values.global.imagePullSecrets | default list }}
{{- $local := .Values.imagePullSecrets | default list }}
{{- $merged := concat $global $local }}
{{- if $merged }}
imagePullSecrets:
{{- toYaml $merged | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Full image reference for the API server.
*/}}
{{- define "radar.app.image" -}}
{{- $registry := coalesce .Values.image.registry .Values.global.imageRegistry }}
{{- $repo := .Values.image.app.repository }}
{{- $tag := .Values.image.app.tag | default .Chart.AppVersion }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repo $tag }}
{{- else }}
{{- printf "%s:%s" $repo $tag }}
{{- end }}
{{- end }}

{{/*
Full image reference for the worker.
*/}}
{{- define "radar.worker.image" -}}
{{- $registry := coalesce .Values.image.registry .Values.global.imageRegistry }}
{{- $repo := .Values.image.worker.repository }}
{{- $tag := .Values.image.worker.tag | default .Chart.AppVersion }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repo $tag }}
{{- else }}
{{- printf "%s:%s" $repo $tag }}
{{- end }}
{{- end }}

{{/*
Full image reference for the migration job.
*/}}
{{- define "radar.migrate.image" -}}
{{- $registry := coalesce .Values.image.registry .Values.global.imageRegistry }}
{{- $repo := .Values.image.migrate.repository }}
{{- $tag := .Values.image.migrate.tag | default .Chart.AppVersion }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repo $tag }}
{{- else }}
{{- printf "%s:%s" $repo $tag }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding database credentials.
*/}}
{{- define "radar.databaseSecretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else }}
{{- printf "%s-database" (include "radar.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the credential encryption key.
*/}}
{{- define "radar.credentialsSecretName" -}}
{{- if .Values.credentials.existingSecret }}
{{- .Values.credentials.existingSecret }}
{{- else }}
{{- printf "%s-credentials" (include "radar.fullname" .) }}
{{- end }}
{{- end }}

{{/*
LaunchDarkly Secret name. Uses launchDarkly.existingSecret when provided,
otherwise the chart-managed Secret.
*/}}
{{- define "radar.launchDarklySecretName" -}}
{{- if .Values.launchDarkly.existingSecret }}
{{- .Values.launchDarkly.existingSecret }}
{{- else }}
{{- printf "%s-launchdarkly" (include "radar.fullname" .) }}
{{- end }}
{{- end }}

{{/*
LaunchDarkly is enabled when either an inline SDK key or an existingSecret is
provided. Empty on both keeps the API on the no-op feature-flag provider.
*/}}
{{- define "radar.launchDarklyEnabled" -}}
{{- if or .Values.launchDarkly.sdkKey .Values.launchDarkly.existingSecret -}}true{{- end -}}
{{- end -}}

{{/*
LaunchDarkly SDK key env entry. optional:true so a release that references an
existingSecret which does not (yet) carry the key never fails to start.
*/}}
{{- define "radar.launchDarklyEnv" -}}
- name: LAUNCHDARKLY_SDK_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "radar.launchDarklySecretName" . }}
      key: LAUNCHDARKLY_SDK_KEY
      optional: true
{{- end -}}

{{/*
Database hostname for the TCP readiness init container.
When the bundled PostgreSQL is enabled the service name is used automatically;
otherwise database.host must be set explicitly.
*/}}
{{- define "radar.database.host" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s-postgresql" .Release.Name }}
{{- else }}
{{- required "database.host is required when postgresql.enabled is false" .Values.database.host }}
{{- end }}
{{- end }}

{{/*
DATABASE_URL constructed from bundled PostgreSQL values. Only evaluated when
postgresql.enabled is true and no existingSecret or database.url is provided.
postgresql.auth.password is required — Bitnami's subchart can auto-generate
one but we'd have no way to read it back into this URL.
urlquery encodes ' ' as '+' (form-encoding); we re-encode it as %20 because
postgres connection-string parsers don't decode '+' as a space.
*/}}
{{- define "radar.postgresql.url" -}}
{{- $password := required "postgresql.auth.password is required when postgresql.enabled is true" .Values.postgresql.auth.password -}}
{{- $encodedUser := .Values.postgresql.auth.username | urlquery | replace "+" "%20" -}}
{{- $encodedPass := $password | urlquery | replace "+" "%20" -}}
{{- $encodedDB   := .Values.postgresql.auth.database | urlquery | replace "+" "%20" -}}
{{- printf "postgres://%s:%s@%s-postgresql:5432/%s?sslmode=disable" $encodedUser $encodedPass .Release.Name $encodedDB }}
{{- end }}

{{/*
Pod security context renderer.

OpenShift restricted-v2 assigns namespace-scoped UIDs/GIDs during admission, so
OpenShift installs must not pin runAsUser or fsGroup. Keep the default pins for
plain Kubernetes, where the BusyBox init/test containers otherwise run as root.
*/}}
{{- define "radar.podSecurityContext" -}}
{{- $root := .root -}}
{{- $context := deepCopy (.context | default dict) -}}
{{- if $root.Values.openshift.enabled -}}
{{- $_ := unset $context "runAsUser" -}}
{{- $_ := unset $context "fsGroup" -}}
{{- end -}}
{{- if $context }}
securityContext:
{{- toYaml $context | nindent 2 }}
{{- end }}
{{- end }}

{{/*
wait-for-db init container. Renders a single init container that TCP-probes
the database before app/worker/migrate pods start. Caller must already be
inside an `initContainers:` block (or about to start one).
*/}}
{{- define "radar.waitForDbInitContainer" -}}
- name: wait-for-db
  image: {{ .Values.dbWaitInitContainer.image.repository }}:{{ .Values.dbWaitInitContainer.image.tag }}
  imagePullPolicy: {{ .Values.dbWaitInitContainer.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      echo "Waiting for database at {{ include "radar.database.host" . }}:{{ .Values.database.port }}..."
      until nc -z {{ include "radar.database.host" . }} {{ .Values.database.port }}; do
        echo "Database not ready, retrying in 2s..."
        sleep 2
      done
      echo "Database is reachable."
  {{- with .Values.dbWaitInitContainer.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.dbWaitInitContainer.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Credential KEK mount helpers. A KEK is available when provided inline
(credentials.kek) or via credentials.existingSecret. When available, the API and
worker pods mount it read-only as a file (0440, read via the pod fsGroup) and
point CREDENTIAL_KEK_PATH at it — so both share one persistent, operator-owned
key instead of each generating an ephemeral one.
*/}}
{{- define "radar.kekEnabled" -}}
{{- if or .Values.credentials.kek .Values.credentials.existingSecret -}}true{{- end -}}
{{- end -}}

{{- define "radar.kekEnv" -}}
- name: CREDENTIAL_KEK_PATH
  value: {{ .Values.credentials.kekPath | quote }}
{{- end -}}

{{/*
KEK provider selector env. CREDENTIAL_KEK_PROVIDER chooses the KEK backend and
defaults to the on-prem file-backed KEK when unset, so leaving credentials.
kekProvider empty preserves existing behaviour. It is emitted independently of
the file-KEK mount (radar.kekEnabled) because the selector is meaningful beyond
the file backend (e.g. a future cloud-KMS backend needs no mounted key file).
*/}}
{{- define "radar.kekProviderEnv" -}}
- name: CREDENTIAL_KEK_PROVIDER
  value: {{ .Values.credentials.kekProvider | quote }}
{{- end -}}

{{- define "radar.kekVolumeMount" -}}
- name: credential-kek
  mountPath: {{ dir .Values.credentials.kekPath | quote }}
  readOnly: true
{{- end -}}

{{- define "radar.kekVolume" -}}
- name: credential-kek
  secret:
    secretName: {{ include "radar.credentialsSecretName" . }}
    items:
      - key: {{ .Values.credentials.kekSecretKey }}
        path: {{ base .Values.credentials.kekPath }}
    defaultMode: 0440
{{- end -}}
