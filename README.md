# mxl-testsrc

A load generator. Runs `mxl-gst-testsrc` in groups of arbitrary size, pinned to named nodes,
producing MXL flows into a domain on the node's filesystem.

This chart produces flows and nothing else. It does not know what consumes them and holds no
opinion about it.

```console
helm install testsrc ./deployment/mxl-testsrc -f my-flows.yaml
```

## A group is a flow spec with a count

```yaml
groups:
  - name: n0-hd
    node: fabrics-on-k8-n0
    domain: /dev/shm/mxl0
    count: 4
    pattern: smpte
    label: "my testsrc %i"
    groupHint: "testsrc-%i"
    video: {width: 1920, height: 1080, rate: {num: 25, den: 1}}
    audio: {enabled: true, rate: 48000}
```

Four pods, eight flows. Pod *n* publishes `testsrc-n:video` and `testsrc-n:audio` — the name comes
from `-g`, and `mxl-gst-testsrc` appends the type itself, lowercase, following the flow definition.
Anything selecting on the group hint name alone picks up both.

`%i` is replaced with the pod's index in `label`, `description`, `groupHint` and `overlayText`. It
is the only thing that differs between the pods of a group, which is what lets one StatefulSet stand
in for the whole group: the chart renders one ConfigMap and one StatefulSet per group whatever
`count` says, and the per-flow values are derived at startup from the pod's ordinal.

Everything in `defaults` is merged under every group, deeply, so a group states only what differs.
Lists replace rather than append. See `values.yaml`, which documents each key.

## Flow ids

Derived, not configured:

```
<key>-0000-4000-8000-<index>   video
<key>-0001-4000-8000-<index>   audio
```

`<key>` is eight hex characters derived from the release and the group name. Two consequences worth
relying on: a pod that restarts republishes the *same* flow rather than leaving the old one behind,
and the id says which pod wrote it — the flow ending `000000000007` is pod 7. Renaming a group
changes the key and so republishes its flows under new ids.

## What it costs

Measured on a 4-core k3s node, one pod each:

| flow | CPU | pod memory | domain |
|---|---|---|---|
| 1080p v210 @25 + stereo audio | 230m | 55 MiB | ~27 MiB |
| 320x180 v210 @25 | 8m | 7 MiB | ~1 MiB |

A 1080p `video/v210` grain is 5.27 MiB and the default ring holds 200 ms of them, so the domain cost
is about five grains per flow. Those pages live in the node's `/dev/shm` and fault into the pod's
cgroup, so the memory limit has to cover the ring as well as the process — the 55 MiB above is
mostly ring. The chart's default 1 GiB limit is generous for one flow and is there so raising the
frame size does not immediately OOM.

The generator is cheaper than the bandwidth suggests: that same 1080p flow is 132 MB/s of writes for
a quarter of a core. What consumes it is where the cost usually is.

When the point is flow count rather than picture, that is all avoidable: small frame sizes cost
close to nothing, `pattern: black` skips the pattern generation, and an audio flow is nearly free
while still being a whole flow to everything downstream. Mixing a few full-rate groups with a large
cheap one is usually what you want.

Raise the batch hints before blaming a consumer for falling behind — the tool's default is one slice
per sync, which is the most syscall-expensive setting available:

```yaml
video: {options: {maxCommitBatchSizeHint: 60, maxSyncBatchSizeHint: 60}}
audio: {options: {maxCommitBatchSizeHint: 512, maxSyncBatchSizeHint: 512}}
```

A generator that has fallen behind looks exactly like a slow consumer from the far end, so check it
first. `mxl-info -d <domain> -f <id>` prints `Latency (grains)`; it should be small and stable.

## Scaling down

`cleanupOnExit` (on by default) removes the pod's flow directories when it shuts down. A flow
directory normally outlives the process that wrote it — that is how a consumer reads across a
producer restart — but for a fixture that is scaled up and down, going from 400 pods to 4 would
otherwise leave 396 flows in the domain with nothing producing them, and anything discovering the
domain would keep finding them. Turn it off to test what a consumer does with a producer that went
away.

## Changing a running group

Scaling is fast: `count` up or down takes effect immediately, because the pods are created and
deleted in parallel. Forty pods went from `helm upgrade` to producing in 29 seconds.

Changing anything *else* — a flow definition, the pattern, the entrypoint — rolls the pods, and a
StatefulSet rolls one at a time in reverse ordinal order however the pods were created. That is
about three seconds a pod, so a group of 200 takes roughly ten minutes and spends it half on each
spec. Set `updateStrategy: {type: OnDelete}` on a group that large and delete its pods yourself, in
batches the node can absorb.

## Notes

- `domain` is an absolute host path, and `hostMounts` must cover it — the chart refuses to render
  otherwise. `mountPath` should equal `hostPath` so the path means the same thing inside the
  container and out.
- `groupHint` must contain `%i` when `count` is greater than one. Also refused, because every pod
  would otherwise publish under one name.
- Group hint names are not checked across groups. Two groups sharing a `groupHint` format and a
  domain publish colliding names; use `startIndex` to offset one of them.
- `video.components` is derived from `width`, `height` and `bitDepth` as 4:2:2, which is what
  `video/v210` is. State it explicitly for any other sampling.
