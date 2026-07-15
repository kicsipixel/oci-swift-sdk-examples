# Multi-stage build for the BucketRelay Hummingbird service.
#
# Build for the architecture of the Container Instance shape you will deploy to:
#   CI.Standard.A1.Flex  -> linux/arm64   (Ampere)
#   CI.Standard.E4.Flex  -> linux/amd64   (x86)
# e.g.  docker build --platform linux/arm64 -t <registry>/bucket-relay:latest .

# ---- Build stage: compile the release binary ----
FROM swift:6.2 AS build
WORKDIR /app
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --product App
RUN mkdir /out && cp "$(swift build -c release --show-bin-path)/App" /out/bucket-relay

# ---- Runtime stage: slim image with just the Swift runtime libraries ----
# (swift-crypto's BoringSSL is statically linked into the binary.)
FROM swift:6.2-slim
WORKDIR /app
COPY --from=build /out/bucket-relay /usr/local/bin/bucket-relay
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bucket-relay"]
