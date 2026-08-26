{{- /*
Runner floor. Tags that parse as semver below runner.minVersion are refused at
render time; non-semver tags (dev, latest, a digest) are left to the init
hook's runtime check.
*/ -}}
{{- $tag := trimPrefix "v" (toString .Values.runner.tag) -}}
{{- if and (regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+" $tag) (not .Values.runner.allowOlder) -}}
{{- if not (semverCompare (printf ">=%s" .Values.runner.minVersion) $tag) -}}
{{- fail (printf "runner.tag %q is older than the required roksbnkctl %s (set runner.allowOlder=true to override)" .Values.runner.tag .Values.runner.minVersion) -}}
{{- end -}}
{{- end -}}
