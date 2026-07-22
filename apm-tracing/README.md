# apm-tracing — OpenTelemetry spans to OCI APM with swift-otel

OCI **Application Performance Monitoring** is the one OCI service that speaks
OpenTelemetry natively, so tracing needs no OCIKit code on the hot path at all: point a
stock OTLP/HTTP exporter at the APM domain's traces endpoint and authenticate with an
APM **data key**.

```
POST <dataUploadEndpoint>/20200101/opentelemetry/public/v1/traces
Authorization: dataKey <APM data key>
Content-Type: application/x-protobuf        # or application/json
```

No signer, no IAM policy, no request signing. This package is the worked example, in
two flavours:

- **`apm-trace-probe`** — any long-running Swift workload (Compute VM, OKE, Container
  Instances). Endpoint and data key come from the environment; the code bootstraps
  swift-otel, emits one trace, and flushes on shutdown.
- **`apm-trace-function`** — an OCI Function. Nothing is configured by hand: it reads
  `OCI_TRACING_ENABLED` / `OCI_TRACE_COLLECTOR_URL` through `OCIKitFunctions`'
  `TracingContext`, retargets the injected legacy Zipkin collector URL onto the same
  domain's OTLP path with `APMCollectorEndpoint`, and parents each invocation's span on
  the platform's `X-B3-*` headers — **left-padding** their 64-bit trace id to the 128
  bits OpenTelemetry requires.

Both share the `APMTracing` library: endpoint composition, the swift-otel configuration
APM needs, and the B3 → W3C trace-context bridge.

> This directory is a **standalone SwiftPM package**. It depends on
> [`oci-swift-sdk`](https://github.com/iliasaz/oci-swift-sdk) from GitHub rather than on a
> sibling checkout, so the function container can be built from this directory alone, with
> nothing else in its Docker context. Keeping the example outside the SDK's own package is
> deliberate too: **swift-otel never enters the SDK's dependency graph**
> ([`OBSERVABILITY.md` §3](https://github.com/iliasaz/oci-swift-sdk/blob/main/OBSERVABILITY.md)).
> Nothing here runs in CI; it must be built and run by hand, and it needs a live APM domain.

---

## Prerequisites

- An **APM domain** (`oci apm-control-plane apm-domain create ...`; the Always Free
  domain is enough), and its `dataUploadEndpoint`:

  ```sh
  APM_DOMAIN=<apm-domain-ocid>
  oci apm-control-plane apm-domain get --profile <profile> --apm-domain-id "$APM_DOMAIN" \
    --query 'data."data-upload-endpoint"' --raw-output
  ```

- A **data key** for that domain. `public` is the one to use for spans:

  ```sh
  oci apm-control-plane data-key list --profile <profile> --apm-domain-id "$APM_DOMAIN" \
    --query "data[?name=='auto_generated_public_datakey'].value | [0]" --raw-output
  ```

  > `ListDataKeys` returns the key **values**, so a policy granting it is as sensitive as
  > the keys themselves. In production, store the key in a **Vault secret** and read it at
  > startup with OCIKit's `SecretsClient.getSecretBundle` under the workload's injected
  > principal — that works on every runtime and needs no extra API surface. On Functions
  > you need neither: the platform injects the public key inside
  > `OCI_TRACE_COLLECTOR_URL`.

- Swift 6.2+ (verified with 6.3.3 on macOS and 6.2.4 on Linux), and Docker for the
  function image.

Nothing in this package hard-codes an endpoint, a key, or an OCID — everything comes from
the environment.

---

## 1. `apm-trace-probe` — a workload on VM / OKE / Container Instances

```sh
export APM_DATA_UPLOAD_ENDPOINT="https://<domain>.apm-agt.<region>.oci.oraclecloud.com"
export APM_DATA_KEY="<APM public data key>"
export APM_SERVICE_NAME="ocikit-apm-trace-probe"     # optional
export APM_SPAN_VISIBILITY="public"                  # optional: public | private
export APM_DIAGNOSTIC_LOG_LEVEL="debug"              # optional: swift-otel's own logging

swift run apm-trace-probe
```

| Variable | Required | Meaning |
|---|---|---|
| `APM_DATA_UPLOAD_ENDPOINT` | yes | The APM domain's `dataUploadEndpoint` |
| `APM_DATA_KEY` | yes | Data key matching `APM_SPAN_VISIBILITY` |
| `APM_SPAN_VISIBILITY` | no (`public`) | `public` or `private` span path |
| `APM_SERVICE_NAME` | no | `service.name` resource attribute |
| `APM_DIAGNOSTIC_LOG_LEVEL` | no (`info`) | `error`/`warning`/`info`/`debug`/`trace` |

### What a real run printed

Run on 2026-07-21 against an Always Free APM domain in `us-phoenix-1`, endpoint and key
redacted, `APM_DIAGNOSTIC_LOG_LEVEL=debug`:

```
info  apm-trace-probe: endpoint=https://<domain>.apm-agt.us-phoenix-1.oci.oraclecloud.com/20200101/opentelemetry/public/v1/traces
                       service.name=ocikit-apm-trace-probe visibility=public [apm_trace_probe] exporting spans to APM
info  apm-trace-probe: traceparent=00-0654f0e1356af5ccfea7b740c5598994-c12b6a84adb22d4d-01 [apm_trace_probe] started root span
info  apm-trace-probe: [apm_trace_probe] trace emitted; shutting down to flush the span processor
debug swift-otel: buffer_size=2 component=OTelBatchSpanProcessor [OTel] Force flushing.
debug swift-otel: component=bootstrap [OTel] Making request.
debug swift-otel: component=bootstrap status_code=200 [OTel] Returning response.
warning swift-otel: batch_id=0 batch_size=2 component=OTelBatchSpanProcessor
                    error.message=responseHasMissingContentType error.type=OTel.OTLPHTTPExporterError [OTel] Failed to export batch.
info  apm-trace-probe: [apm_trace_probe] done
```

**`status_code=200` — the spans were accepted.** The `Failed to export batch` warning
right after it is spurious; see [Caveats](#caveats) below.

### Confirming the spans in APM

Take the trace id out of the logged `traceparent`
(`00-<trace id>-<span id>-<flags>`) and read the trace back. Ingestion is asynchronous —
in this run the trace materialised roughly **30 seconds** after the export, so retry for
a couple of minutes before concluding anything:

```sh
oci apm-traces trace trace get --profile <profile> --apm-domain-id "$APM_DOMAIN" \
  --trace-key 0654f0e1356af5ccfea7b740c5598994
```

```
trace key      : 0654f0e1356af5ccfea7b740c5598994
span count     : 2
root operation : apm-trace-probe request
root service   : ocikit-apm-trace-probe
trace status   : COMPLETE
  span c12b6a84adb22d4d | parent None             | SERVER   | 'apm-trace-probe request' | ocikit-apm-trace-probe
  span 20f8f755ffacf8d4 | parent c12b6a84adb22d4d | INTERNAL | 'apm-trace-probe work'    | ocikit-apm-trace-probe
```

The same spans are queryable through Trace Explorer:

```sh
oci apm-traces query query-response run-query --profile <profile> --apm-domain-id "$APM_DOMAIN" \
  --query-text "show spans traceId, operationName, serviceName where serviceName = 'ocikit-apm-trace-probe'" \
  --start-time-gte 2026-07-21T00:00:00Z --start-time-lt 2026-07-22T00:00:00Z --limit 10
```

```json
"query-result-rows": [
  { "query-result-row-data": { "operationName": "apm-trace-probe work",
                               "serviceName": "ocikit-apm-trace-probe",
                               "traceId": "0654f0e1356af5ccfea7b740c5598994" } },
  { "query-result-row-data": { "operationName": "apm-trace-probe request",
                               "serviceName": "ocikit-apm-trace-probe",
                               "traceId": "0654f0e1356af5ccfea7b740c5598994" } }
]
```

---

## 2. `apm-trace-function` — an OCI Function

Enable tracing on the application **and** the function (Console → the application →
Traces, or `oci fn application update --trace-config ...`) and the platform injects
everything the exporter needs. The function reads it through `OCIKitFunctions`:

```swift
let runtime = RuntimeContext.fromEnvironment()
let tracing = TracingContext(runtime: runtime, headers: FunctionHeaders())
guard let endpoint = tracing.collectorEndpoint else { /* serve untraced */ }
// endpoint.otlpTracesURL  ->  https://<domain>.../20200101/opentelemetry/public/v1/traces
// endpoint.dataKey        ->  the public data key lifted out of OCI_TRACE_COLLECTOR_URL
```

and per invocation:

```swift
let tracing = context.tracing
let parent = B3TraceContext(traceID: tracing.traceId, spanID: tracing.spanId, isSampled: tracing.isSampled)
try await withSpan("…", context: parent?.serviceContext ?? .topLevel, ofKind: .server) { span in … }
```

`B3TraceContext` is the whole bridge: the platform's ids are **64-bit** Zipkin B3 ids and
OpenTelemetry's are **128-bit**, so the trace id is left-padded with zeros (`518254ac…` →
`0000000000000000518254ac…`) and rendered as a W3C `traceparent`. swift-otel 1.5.0 ships
no B3 propagator — `OTel.Configuration.Propagator.b3` and `.b3Multi` trap with *"Swift
OTel does not support the B3 … propagator"* — so the padded ids go in through the
`traceContext` propagator, which is enabled by default.

### Running it without deploying

The FDK's contract is an HTTP/1.1 server on a Unix domain socket, so the function can be
exercised locally against a fake listener. This is exactly how the run recorded below was
produced:

```sh
mkdir -p /tmp/ocikitfn                # keep the path short: sun_path is 104 bytes
swift build

FN_FORMAT=http-stream \
FN_LISTENER=unix:/tmp/ocikitfn/lsnr.sock \
FN_APP_NAME=ocikit-observability FN_FN_NAME=apm-trace-function \
OCI_TRACING_ENABLED=1 \
OCI_TRACE_COLLECTOR_URL="https://<domain>.apm-agt.<region>.oci.oraclecloud.com/20200101/observations/public-span?dataFormat=zipkin&dataFormatVersion=2&dataKey=<APM public data key>" \
./.build/debug/apm-trace-function &

curl -sS --unix-socket /tmp/ocikitfn/lsnr.sock -X POST http://localhost/call \
  -H "Fn-Call-Id: 01HZTESTCALLID000000000001" \
  -H "X-B3-TraceId: 518254acae02a405" -H "X-B3-SpanId: 56da568e23432251" \
  --data "hello from a b3-traced invoke"

kill %1                               # SIGTERM: stops the serve loop, then flushes spans
```

The server and the swift-otel exporter run in one `ServiceGroup` with
`gracefulShutdownSignals: [.sigterm, .sigint]`, and services shut down in reverse order —
so `TracedFunctionService` has to *return* when shutdown is signalled for the exporter
behind it to get its shutdown-time flush. Graceful shutdown is not task cancellation and
the FDK's serve loop ends only when its socket closes, hence the `cancelWhenGracefulShutdown`
wrapper in `TracedFunctionService.run()`; without it `SIGTERM`/`docker stop` would hang the
process until the platform's `SIGKILL`.

Startup log (endpoint redacted) — note that the injected *Zipkin* URL has been retargeted
onto the OTLP path, and that `service.name` is the conventional `<app>::<function>`:

```
info apm-trace-function: endpoint=https://<domain>.apm-agt.us-phoenix-1.oci.oraclecloud.com/20200101/opentelemetry/public/v1/traces
                         service.name=ocikit-observability::apm-trace-function visibility=public [apm_trace_function] exporting spans to APM
info swift-otel: component=bootstrap [OTel] Bootstrapping instrumentation system with OTLP/HTTP+Protobuf exporter.
info apm-trace-function: [OCIKitFunctions] OCIKitFunctions serving on /tmp/ocikitfn/lsnr.sock (bound at /tmp/ocikitfn/phonylsnr.sock)
```

The invocation's reply shows the padding:

```json
{"b3TraceID":"518254acae02a405",
 "otelTraceparent":"00-0000000000000000518254acae02a405-6fc388027fefff35-01",
 "serviceName":"ocikit-observability::apm-trace-function",
 "echo":"hello from a b3-traced invoke"}
```

and the trace read back from APM ~30 s later shows the handler's span **parented on the
platform's span id** (`56da568e23432251`, the injected `X-B3-SpanId`), under the padded
128-bit trace key:

```sh
oci apm-traces trace trace get --profile <profile> --apm-domain-id "$APM_DOMAIN" \
  --trace-key 0000000000000000518254acae02a405
```

```
trace key : 0000000000000000518254acae02a405
spans     : 2
  6fc388027fefff35 | parent 56da568e23432251 | SERVER   | 'apm-trace-function invocation' | ocikit-observability::apm-trace-function
  689044b4325c7ca0 | parent 6fc388027fefff35 | INTERNAL | 'apm-trace-function work'       | ocikit-observability::apm-trace-function
```

In this local run the parent `56da568e23432251` is synthetic, so APM reports no root span
for the trace; deployed on Functions that id belongs to the platform's own
`function invocation` span and the two halves join into one trace.

### Deploying it

The `Dockerfile` here builds `apm-trace-function` the same way the SDK's
[`Tests/functions-live-test`](https://github.com/iliasaz/oci-swift-sdk/blob/main/Tests/functions-live-test/README.md)
builds its function (multi-stage `swift:6.2` → `swift:6.2-slim`, non-root `fn` user at
uid/gid 1000). Follow that README for the OCIR push, application/function creation and
IAM steps; the only addition is enabling tracing on the application and the function, and
giving the function egress to the APM data-upload endpoint. Nothing else is needed: no
function configuration, no dynamic group, no policy — APM ingestion is
data-key-authenticated.

---

## Caveats

Ingestion facts from the SDK's
[`OBSERVABILITY.md`](https://github.com/iliasaz/oci-swift-sdk/blob/main/OBSERVABILITY.md)
§2.3, plus what this example ran into.

- **Span links are dropped.** APM does not support OpenTelemetry span links; they are
  silently discarded on ingestion. Model causality with parent/child spans instead.
- **There is no OTLP logs endpoint.** APM ingests traces (and, on the private path,
  metrics) only — an OTLP *logs* exporter has nowhere to point. Application logs go to
  OCI Logging, which OCIKit's `OCILogHandler` writes over `PutLogs`. This example
  therefore sets `configuration.logs.enabled = false`.
- **OTLP metrics require the domain's *private* data key** (`/20200101/opentelemetry/v1/metrics`;
  there is no public metrics path), and land in OCI Monitoring under the
  `oracle_apm_monitoring` namespace. OCIKit's `OCIMetricsFactory` posts to OCI Monitoring
  directly under an injected OCI principal instead, so this example sets
  `configuration.metrics.enabled = false`.
- **Always Free is capped at 1,000 tracing events per hour, per tenancy.** Ample for an
  example; not a load-test target. A chatty service on a Free domain will have spans
  rejected once the hour's budget is spent.
- **swift-otel 1.5.0 logs a spurious `Failed to export batch` warning after every
  successful APM export.** Live-verified: APM answers a successful OTLP POST with
  `HTTP/1.1 200 OK`, `Content-Length: 0` and **no `Content-Type` header** (for both
  `application/json` and `application/x-protobuf` requests). swift-otel's OTLP/HTTP
  exporter accepts a bodyless response only when the status is `204 No Content`, so on
  `200` with no content type it throws `responseHasMissingContentType` and the batch
  processor logs a warning — *after* the server has already accepted and stored the
  spans. The data is not lost; the warning is. Judge success by
  `status_code=200` (visible at `APM_DIAGNOSTIC_LOG_LEVEL=debug`) and by reading the
  trace back, not by the absence of that warning.
- **A Functions container is frozen once it responds**, so a batch still sitting in the
  span processor is not sent until the container thaws for the next invocation. The
  function variant therefore shortens `traces.batchSpanProcessor.scheduleDelay` to
  200 ms (OTel's default is 5 s), trading one HTTP request per invocation for spans that
  actually leave the container. swift-otel exposes no public force-flush.
- **Ingestion is asynchronous.** In these runs the spans were readable through
  `oci apm-traces` about 30 seconds after the 200, and not before. Retry the read for a
  couple of minutes before deciding an export failed.
- **The `apm-traces` API returns only APM-computed span tags** (`ApdexLevel`,
  `ApdexScore`, `SpanErrorCount`, `ReportPeriod`); the custom OTLP span attributes this
  example sets were not echoed back by `trace span get` in these runs.

## Building

```sh
swift build --package-path .                                     # macOS
docker run --rm -v "$PWD":/pkg -w /pkg swift:6.2 swift build     # Linux
```

`Package.swift` resolves `oci-swift-sdk` from GitHub at `main` — deliberately, so the
`Dockerfile` can build the function from this directory alone. To build against a local
SDK checkout instead (a branch, or edits you haven't pushed), point SwiftPM at it. The
path below assumes `oci-swift-sdk` is checked out beside `oci-swift-sdk-examples`; adjust
it if yours lives elsewhere:

```sh
swift package edit oci-swift-sdk --path ../../oci-swift-sdk   # undo: swift package unedit oci-swift-sdk
```

That only touches `.build/` and `Packages/`, so there is nothing to commit.

Verified on 2026-07-21 with Swift 6.3.3 (macOS, arm64) and Swift 6.2.4 (Linux,
aarch64), against swift-otel 1.5.0, swift-distributed-tracing 1.4.1 and
swift-service-lifecycle 2.11.0. Only the `OTLPHTTP` package trait is enabled, so
grpc-swift is not fetched or built.
