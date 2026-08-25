{{/*
Common labels. Every object the chart renders carries the workspace label so
`kubectl get all -l roksbnkctl.io/workspace=<ws>` shows one lifecycle.
*/}}
{{- define "bnk.labels" -}}
app.kubernetes.io/name: bnk-workspace
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
roksbnkctl.io/workspace: {{ .Values.workspace | quote }}
{{- end }}

{{- define "bnk.image" -}}
{{ .Values.runner.image }}:{{ .Values.runner.tag }}
{{- end }}

{{/* cwc-guard: "auto" => only on the BNK 2.3 line (the f5-spk-cwc Multi-Attach defect). */}}
{{- define "bnk.cwcGuard" -}}
{{- if eq (toString .Values.cwcGuard.enabled) "auto" -}}
{{- if eq (toString .Values.line) "2.3" }}true{{ else }}false{{ end -}}
{{- else -}}
{{- if .Values.cwcGuard.enabled }}true{{ else }}false{{ end -}}
{{- end -}}
{{- end }}

{{/*
Shell prelude shared by every hook. Provides:
  local_kubectl        kubectl against the cluster the Job runs in (Argo CD's
                       destination) via the pod ServiceAccount — never the ROKS
                       admin kubeconfig roksbnkctl fetches, which may be a
                       different cluster in the hub topology.
  write_status         merge-patch the bnk-status ConfigMap (data only, so Argo
                       CD's tracking metadata is untouched). Argo CD's Lua health
                       check turns it into Application health.
  deployed_now         "true"/"false"/"unknown" from `bnk status --json`.
*/}}
{{- define "bnk.prelude" -}}
set -eu
WS={{ .Values.workspace | quote }}
LIFECYCLE={{ .Values.lifecycle | quote }}
STATUS_CM={{ .Values.status.configMapName | quote }}
HOOK_NAME=${HOOK_NAME:-unknown}
SA=/var/run/secrets/kubernetes.io/serviceaccount
LOCAL_KUBECONFIG=/tmp/local.kubeconfig
# jq: .deployed may be false — `//` would turn that into "unknown"
DEPLOYED_JQ='if has("deployed") and .deployed != null then (.deployed|tostring) else "unknown" end'
local_kubectl() { kubectl --kubeconfig="$LOCAL_KUBECONFIG" "$@"; }
mk_local_kubeconfig() {
  [ -f "$LOCAL_KUBECONFIG" ] && return 0
  local_kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority="$SA/ca.crt" >/dev/null
  local_kubectl config set-credentials sa --token="$(cat "$SA/token")" >/dev/null
  local_kubectl config set-context local --cluster=local --user=sa --namespace="$(cat "$SA/namespace")" >/dev/null
  local_kubectl config use-context local >/dev/null
}
# write_status <outcome: running|succeeded|failed> <deployed: true|false|unknown> <message> [status.json]
write_status() {
  mk_local_kubeconfig
  patch=$(jq -n --arg lifecycle "$LIFECYCLE" --arg outcome "$1" --arg deployed "$2" --arg message "$3" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "$HOOK_NAME" --rawfile status "${4:-/dev/null}" \
    '{data:{lifecycle:$lifecycle,outcome:$outcome,deployed:$deployed,message:$message,updatedAt:$at,lastHook:$hook,"status.json":$status}}')
  if ! local_kubectl get configmap "$STATUS_CM" >/dev/null 2>&1; then
    local_kubectl create configmap "$STATUS_CM" >/dev/null 2>&1 || true
  fi
  local_kubectl patch configmap "$STATUS_CM" --type merge -p "$patch" >/dev/null
  echo "[status] $1 deployed=$2 — $3"
}
deployed_now() {
  roksbnkctl -w "$WS" bnk status --json 2>/dev/null | jq -r "$DEPLOYED_JQ" 2>/dev/null || echo unknown
}
{{- end }}

{{/*
The runner container, shared by every hook Job. `args` is supplied by the caller.
*/}}
{{- define "bnk.runnerContainer" -}}
image: {{ include "bnk.image" . | quote }}
imagePullPolicy: {{ .Values.runner.imagePullPolicy }}
command: ["/bin/sh", "-c"]
workingDir: /work
envFrom:
  - configMapRef:
      name: {{ .Values.env.configMapName }}
  {{- if ne .Values.secrets.mode "none" }}
  - secretRef:
      name: {{ .Values.secrets.name }}
  {{- end }}
  {{- range .Values.runner.extraEnvFrom }}
  - {{ toYaml . | nindent 4 | trim }}
  {{- end }}
env:
  - name: ROKSBNKCTL_HOME
    value: /work/.roksbnkctl
  - name: HOME
    value: /home/runner
  - name: WS
    value: {{ .Values.workspace | quote }}
  {{- range $k, $v := .Values.runner.env }}
  - name: {{ $k }}
    value: {{ $v | quote }}
  {{- end }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
{{- with .Values.runner.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumeMounts:
  - name: work
    mountPath: /work
  - name: signal
    mountPath: /signal
  - name: tmp
    mountPath: /tmp
{{- end }}

{{/*
A hook Job. Call with a dict:
  root, name, hook (PreSync|Sync|PostSync|SyncFail|PreDelete), wave (string),
  deadline (seconds), script (string), cwc (bool: add the cwc-guard container)
*/}}
{{- define "bnk.hookJob" -}}
{{- $r := .root -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .name }}
  namespace: {{ $r.Values.namespace }}
  labels:
    {{- include "bnk.labels" $r | nindent 4 }}
    roksbnkctl.io/hook: {{ .name }}
  annotations:
    argocd.argoproj.io/hook: {{ .hook }}
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
    argocd.argoproj.io/hook-delete-policy: {{ $r.Values.hooks.deletePolicy }}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: {{ .deadline }}
  template:
    metadata:
      labels:
        {{- include "bnk.labels" $r | nindent 8 }}
        roksbnkctl.io/hook: {{ .name }}
    spec:
      serviceAccountName: {{ $r.Values.serviceAccount.name }}
      restartPolicy: Never
      {{- with $r.Values.runner.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
        {{- with $r.Values.runner.fsGroup }}
        fsGroup: {{ . }}
        {{- end }}
        {{- with $r.Values.runner.runAsUser }}
        runAsUser: {{ . }}
        {{- end }}
      {{- with $r.Values.runner.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $r.Values.runner.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumes:
        - name: work
          persistentVolumeClaim:
            claimName: {{ $r.Values.storage.claimName }}
        - name: signal
          emptyDir: {}
        - name: tmp
          emptyDir: {}
      containers:
        - name: {{ .name }}
          {{- include "bnk.runnerContainer" $r | nindent 10 }}
          args:
            - |
              HOOK_NAME={{ .name }}
              {{- include "bnk.prelude" $r | nindent 14 }}
              {{- .script | nindent 14 }}
        {{- if .cwc }}
        - name: cwc-guard
          {{- include "bnk.runnerContainer" $r | nindent 10 }}
          args:
            - |
              HOOK_NAME=cwc-guard
              {{- include "bnk.prelude" $r | nindent 14 }}
              {{- $r.Values.cwcGuard.script | nindent 14 }}
        {{- end }}
{{- end }}
