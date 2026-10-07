{{/*
Names.
*/}}
{{- define "mxl-testsrc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mxl-testsrc.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mxl-testsrc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels. `commonLabels` is merged in last so an operator can override anything the chart sets.
*/}}
{{- define "mxl-testsrc.labels" -}}
helm.sh/chart: {{ include "mxl-testsrc.chart" . }}
app.kubernetes.io/name: {{ include "mxl-testsrc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mxl-testsrc
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels for one group. Immutable on a StatefulSet, so `commonLabels` is deliberately *not*
in here: adding a label after the fact would otherwise make an upgrade fail.

Usage: include "mxl-testsrc.selectorLabels" (dict "root" $ "group" "n0-hd")
*/}}
{{- define "mxl-testsrc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mxl-testsrc.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .group }}
{{- end -}}

{{- define "mxl-testsrc.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.registry -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
One group, with `defaults` merged underneath it, validated.

Every template that touches a group goes through here, so the checks run once per group however
many objects it renders.

Usage: $g := include "mxl-testsrc.group" (dict "root" $ "group" $group) | fromYaml
*/}}
{{- define "mxl-testsrc.group" -}}
{{- $g := mergeOverwrite (deepCopy .root.Values.defaults) (deepCopy .group) -}}
{{- if not $g.name -}}
{{- fail "every entry in `groups` needs a `name`, which is unique and becomes the StatefulSet's suffix" -}}
{{- end -}}
{{- if lt (int $g.count) 1 -}}
{{- fail (printf "group %q: `count` is %v, so it produces nothing. Remove the group instead." $g.name $g.count) -}}
{{- end -}}
{{- if and (not $g.video.enabled) (not $g.audio.enabled) -}}
{{- fail (printf "group %q: neither `video.enabled` nor `audio.enabled` is set, so its pods would produce no flows" $g.name) -}}
{{- end -}}
{{- if and (gt (int $g.count) 1) (not (contains "%i" $g.groupHint)) -}}
{{- fail (printf "group %q: `count` is %v but `groupHint` is %q, which has no `%%i`. All %v pods would publish under one name and nothing downstream could tell them apart." $g.name $g.count $g.groupHint $g.count) -}}
{{- end -}}
{{- if not (hasPrefix "/" $g.domain) -}}
{{- fail (printf "group %q: `domain` is %q. It must be an absolute path, because it names a directory on the node." $g.name $g.domain) -}}
{{- end -}}
{{- $covered := false -}}
{{- range $mount := $g.hostMounts -}}
{{- $prefix := trimSuffix "/" $mount.mountPath -}}
{{- if or (eq $g.domain $mount.mountPath) (hasPrefix (printf "%s/" $prefix) $g.domain) -}}
{{- $covered = true -}}
{{- end -}}
{{- end -}}
{{- if not $covered -}}
{{- fail (printf "group %q: domain %q is not inside any `hostMounts` entry, so the container cannot see it. Add a hostMounts entry covering it, or correct the path." $g.name $g.domain) -}}
{{- end -}}
{{- toYaml $g -}}
{{- end -}}

{{/*
The eight hex characters that prefix every flow id of a group.

Derived from the release and the group name, so it is stable across renders and across restarts,
and distinct for two groups sharing a domain. The index goes in the last field, which leaves the
id readable: the flow ending in 000000000007 is pod 7 of this group.

Usage: include "mxl-testsrc.flowKey" (dict "root" $ "group" $g)
*/}}
{{- define "mxl-testsrc.flowKey" -}}
{{- printf "%s/%s" (include "mxl-testsrc.fullname" .root) .group.name | sha256sum | trunc 8 -}}
{{- end -}}

{{/*
The video flow definition. `@ID@` and `%i` are substituted by the entrypoint.

The group hint tag is written out for completeness and is then overridden by `-g`, which is what
carries the templated name. `mxl-gst-testsrc` appends the type itself, lowercase, so what ends up in
the published flow_def.json is `<name>:video` — matched here so the two agree.

Usage: include "mxl-testsrc.videoFlow" (dict "group" $g)
*/}}
{{- define "mxl-testsrc.videoFlow" -}}
{{- $g := .group -}}
{{- $v := $g.video -}}
{{- $components := $v.components -}}
{{- if not $components -}}
{{- $components = list
      (dict "name" "Y"  "width" (int $v.width)          "height" (int $v.height) "bit_depth" (int $v.bitDepth))
      (dict "name" "Cb" "width" (div (int $v.width) 2)  "height" (int $v.height) "bit_depth" (int $v.bitDepth))
      (dict "name" "Cr" "width" (div (int $v.width) 2)  "height" (int $v.height) "bit_depth" (int $v.bitDepth)) -}}
{{- end -}}
{{- dict
      "id" "@ID@"
      "label" $g.label
      "description" $g.description
      "format" "urn:x-nmos:format:video"
      "media_type" $v.mediaType
      "parents" (list)
      "tags" (dict "urn:x-nmos:tag:grouphint/v1.0" (list (printf "%s:video" $g.groupHint)))
      "grain_rate" (dict "numerator" (int $v.rate.num) "denominator" (int $v.rate.den))
      "frame_width" (int $v.width)
      "frame_height" (int $v.height)
      "interlace_mode" $v.interlaceMode
      "colorspace" $v.colorspace
      "components" $components
   | toPrettyJson -}}
{{- end -}}

{{/*
The audio flow definition. `channel_count` is MXL's own addition to NMOS and is required.

Usage: include "mxl-testsrc.audioFlow" (dict "group" $g)
*/}}
{{- define "mxl-testsrc.audioFlow" -}}
{{- $g := .group -}}
{{- $a := $g.audio -}}
{{- dict
      "id" "@ID@"
      "label" $g.label
      "description" $g.description
      "format" "urn:x-nmos:format:audio"
      "media_type" $a.mediaType
      "parents" (list)
      "tags" (dict "urn:x-nmos:tag:grouphint/v1.0" (list (printf "%s:audio" $g.groupHint)))
      "sample_rate" (dict "numerator" (int $a.rate))
      "channel_count" (int $a.channels)
      "bit_depth" (int $a.bitDepth)
   | toPrettyJson -}}
{{- end -}}
