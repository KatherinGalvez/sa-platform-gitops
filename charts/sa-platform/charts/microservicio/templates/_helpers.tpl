{{/*
Nombre único de ESTA instancia del subchart. Usamos .Chart.Name (no
.Release.Name) porque Helm sustituye automáticamente .Chart.Name por el
"alias" declarado en el Chart.yaml del padre para cada instancia — así
"auth-service", "cursos-service", "api-gateway", etc. generan nombres
distintos aunque compartan exactamente las mismas plantillas.
.Release.Name es el MISMO para las 8 instancias (todo pertenece al mismo
release de Helm), así que usarlo aquí habría causado colisión de nombres.
Ejemplo de NAMED TEMPLATE #1 — reutilizado por todas las demás plantillas.
*/}}
{{- define "microservicio.fullname" -}}
{{- printf "%s" .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels comunes aplicados a TODOS los recursos generados por este subchart,
siguiendo la convención estándar de Kubernetes (app.kubernetes.io/*).
Ejemplo de NAMED TEMPLATE #2.
*/}}
{{- define "microservicio.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sa-platform
{{- end -}}

{{/*
Subconjunto de labels usado específicamente como selector (Deployment,
Service, HPA, PDB, NetworkPolicy deben todos coincidir en esto). Se separa
de "microservicio.labels" porque el selector NO debe cambiar entre
revisiones (a diferencia de app.kubernetes.io/version, que sí cambia).
*/}}
{{- define "microservicio.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
