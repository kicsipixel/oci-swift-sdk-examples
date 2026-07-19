# Multi-stage build for the swift-oke Hummingbird service.
#
# Build for the architecture of your OKE node pool:
#   Ampere (A1) nodes -> linux/arm64
#   x86    (E-flex)   -> linux/amd64
# e.g.  docker build --platform linux/arm64 -t <region>.ocir.io/<ns>/swift-oke:latest .
#
# No CA/trust-store step is required: OKEWorkloadIdentitySigner pins the cluster
# CA in-process (AsyncHTTPClient + NIOSSL), and swift-crypto's BoringSSL is
# statically linked into the binary.

# ---- Build stage: compile the release binary ----
FROM swift:6.2 AS build
WORKDIR /app
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --product App
RUN mkdir /out && cp "$(swift build -c release --show-bin-path)/App" /out/swift-oke

# ---- Runtime stage: slim image with just the Swift runtime libraries ----
FROM swift:6.2-slim
WORKDIR /app
COPY --from=build /out/swift-oke /usr/local/bin/swift-oke
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/swift-oke"]
