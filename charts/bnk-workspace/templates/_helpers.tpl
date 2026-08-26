{{/*
Common labels. Every object the chart renders carries the workspace label so
`kubectl get all -l roksbnkctl.io/workspace=<ws>` shows one lifecycle.
*/}}
{{- define "bnk.labels" -}}
app.kubernetes.io/name: bnk-workspace
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
roksbnkctl.io/workspace: {{ .Values.workspace | quote }}
roksbnkctl.io/line: {{ .Values.line | quote }}
roksbnkctl.io/sizing-profile: {{ .Values.sizing.profile | default "custom" | quote }}
{{- with (include "bnk.manifestVersion" .) }}
roksbnkctl.io/bnk-version: {{ . | quote }}
{{- end }}
{{- end }}

{{/* config mode = a non-empty .Values.config */}}
{{- define "bnk.configMode" -}}{{ if .Values.config }}true{{ else }}false{{ end }}{{- end }}

{{/* The workspace config with the sizing profile merged in (config mode only). */}}
{{- define "bnk.effectiveConfig" -}}
{{- $cfg := deepCopy .Values.config -}}
{{- $profiles := dict
  "baseline" (dict "wpz" 1 "flavor" "bx2.16x64" "tmm" 1)
  "small"    (dict "wpz" 2 "flavor" "bx2.8x32"  "tmm" 3)
  "medium"   (dict "wpz" 2 "flavor" "cx2.16x32" "tmm" 3)
  "large"    (dict "wpz" 3 "flavor" "cx2.48x96" "tmm" 9) -}}
{{- $profile := .Values.sizing.profile | default "custom" -}}
{{- if hasKey $profiles $profile -}}
{{- $p := get $profiles $profile -}}
{{- $cl := (get $cfg "cluster") | default dict -}}
{{- $_ := set $cl "workers_per_zone" (get $p "wpz") -}}
{{- $_ := set $cl "worker_flavor" (get $p "flavor") -}}
{{- $_ := set $cfg "cluster" $cl -}}
{{- $b := (get $cfg "bnk") | default dict -}}
{{- $_ := set $b "tmm_replicas" (get $p "tmm") -}}
{{- $_ := set $b "cneinstance_size" .Values.sizing.deploymentSize -}}
{{- $_ := set $cfg "bnk" $b -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end }}

{{/* cluster.create / cluster.name: from config in config mode, else from values */}}
{{- define "bnk.clusterCreate" -}}
{{- if .Values.config -}}{{ if (dig "cluster" "create" false .Values.config) }}true{{ else }}false{{ end }}{{- else -}}{{ if .Values.cluster.create }}true{{ else }}false{{ end }}{{- end -}}
{{- end }}
{{- define "bnk.clusterName" -}}
{{- if .Values.config -}}{{ dig "cluster" "name" "" .Values.config }}{{- else -}}{{ .Values.cluster.name }}{{- end -}}
{{- end }}
{{- define "bnk.manifestVersion" -}}
{{- if .Values.config -}}{{ dig "bnk" "manifest_version" "" .Values.config }}{{- else -}}{{ index .Values.env "ROKSBNKCTL_MANIFEST_VERSION" | default "" }}{{- end -}}
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
# Version change detection. BNK does not support in-place upgrades: compare the
# desired manifest version with the one recorded by the last apply. Prints
# "<applied> <desired>" when an applied workspace's version differs, else nothing.
version_change() {
  ws_dir="${ROKSBNKCTL_HOME:-/work/.roksbnkctl}/$WS"
  applied_f="$ws_dir/state/terraform.applied.tfvars"
  st="$ws_dir/state/terraform.tfstate"
  [ -f "$applied_f" ] && [ -f "$st" ] || return 0
  [ "$(jq -r '.resources | length' "$st" 2>/dev/null || echo 0)" != "0" ] || return 0
  applied=$(sed -n 's/^f5_bigip_k8s_manifest_version *= *"\(.*\)".*/\1/p' "$applied_f" | head -1)
  desired="${ROKSBNKCTL_MANIFEST_VERSION:-}"
  [ -n "$applied" ] && [ -n "$desired" ] && [ "$applied" != "$desired" ] && echo "$applied $desired"
  return 0
}
# roksbnkctl `bnk status` reports deployed=true whenever the phase's state file
# exists — including right after `bnk down`, when it holds zero resources. Cross-
# check the Terraform state so a torn-down workspace reports deployed=false.
deployed_now() {
  d=$(roksbnkctl -w "$WS" bnk status --json 2>/dev/null | jq -r "$DEPLOYED_JQ" 2>/dev/null || echo unknown)
  st="${ROKSBNKCTL_HOME:-/work/.roksbnkctl}/$WS/state/terraform.tfstate"
  if [ "$d" = "true" ] && { [ ! -f "$st" ] || [ "$(jq -r '.resources | length' "$st" 2>/dev/null || echo 1)" = "0" ]; }; then d=false; fi
  echo "$d"
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
  # HOME is per-pod; the admin kubeconfig `kubeconfig --download` fetches must
  # land on the PVC so later hooks (status probe, cwc-guard) can use it.
  - name: KUBECONFIG
    value: /work/.roksbnkctl/.kube/config
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
  {{- if .Values.config }}
  - name: config
    mountPath: {{ .Values.workspaceConfig.mountPath }}
    readOnly: true
  {{- end }}
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
        {{- if $r.Values.config }}
        - name: config
          configMap:
            name: {{ $r.Values.workspaceConfig.configMapName }}
        {{- end }}
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
