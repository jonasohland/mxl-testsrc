#!/bin/bash
#
# Entrypoint for one mxl-gst-testsrc pod.
#
# Everything that differs between the pods of a group is a function of the pod's ordinal, which is
# the only thing that distinguishes them: the flow ids, the group hint, the label and the overlay
# text. The chart renders the parts that are the same for the whole group and this expands the rest.
#
# Anything passed on the command line is appended to the mxl-gst-testsrc argument list.

set -euo pipefail

: "${MXL_TESTSRC_DOMAIN:?}"
: "${MXL_TESTSRC_KEY:?}"
: "${MXL_TESTSRC_GROUP_HINT:?}"

ordinal="${HOSTNAME##*-}"
case "${ordinal}" in
'' | *[!0-9]*)
    echo "run.sh: cannot derive an ordinal from hostname '${HOSTNAME}'" >&2
    exit 1
    ;;
esac
index=$((ordinal + ${MXL_TESTSRC_START_INDEX:-0}))

# The one substitution this script exists for. sed rather than printf, so a template containing a
# per cent sign that is not '%i' means itself.
expand() {
    printf '%s' "$1" | sed "s/%i/${index}/g"
}

flow_id() {
    printf '%s-%s-4000-8000-%012d' "${MXL_TESTSRC_KEY}" "$1" "${index}"
}

group_hint="$(expand "${MXL_TESTSRC_GROUP_HINT}")"
overlay="$(expand "${MXL_TESTSRC_OVERLAY:-${group_hint}}")"

mkdir -p "${MXL_TESTSRC_DOMAIN}"

args=(
    -d "${MXL_TESTSRC_DOMAIN}"
    -g "${group_hint}"
    -t "${overlay}"
)
if [ -n "${MXL_TESTSRC_PATTERN:-}" ]; then
    args+=(-p "${MXL_TESTSRC_PATTERN}")
fi

flows=()

if [ "${MXL_TESTSRC_VIDEO:-false}" = "true" ]; then
    id="$(flow_id 0000)"
    sed -e "s/@ID@/${id}/" -e "s/%i/${index}/g" /config/video.json >/tmp/video.json
    args+=(-v /tmp/video.json)
    if [ -f /config/video-options.json ]; then
        args+=(--video-options-file /config/video-options.json)
    fi
    flows+=("${MXL_TESTSRC_DOMAIN}/${id}.mxl-flow")
    echo "run.sh: video flow ${id}, group hint '${group_hint}:Video'"
fi

if [ "${MXL_TESTSRC_AUDIO:-false}" = "true" ]; then
    id="$(flow_id 0001)"
    sed -e "s/@ID@/${id}/" -e "s/%i/${index}/g" /config/audio.json >/tmp/audio.json
    args+=(-a /tmp/audio.json)
    if [ -f /config/audio-options.json ]; then
        args+=(--audio-options-file /config/audio-options.json)
    fi
    flows+=("${MXL_TESTSRC_DOMAIN}/${id}.mxl-flow")
    echo "run.sh: audio flow ${id}, group hint '${group_hint}:Audio'"
fi

# exec would be the obvious thing, but then nothing runs after the generator exits and a scaled-down
# group leaves its flow directories behind for whatever is discovering the domain to keep finding.
mxl-gst-testsrc "${args[@]}" "$@" &
child=$!
trap 'kill -TERM "${child}" 2>/dev/null || true' TERM INT

set +e
wait "${child}"
rc=$?
# A trapped signal interrupts wait; the child is still being torn down, so wait for it again.
if [ "${rc}" -gt 128 ]; then
    wait "${child}"
    rc=$?
fi
set -e

if [ "${MXL_TESTSRC_CLEANUP:-true}" = "true" ] && [ "${#flows[@]}" -gt 0 ]; then
    rm -rf "${flows[@]}"
fi

exit "${rc}"
