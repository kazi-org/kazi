# Multi-stage build for the kazi deploy-target fixture.
# Builds with Podman or Docker; the final image listens on $PORT (Cloud Run).

FROM golang:1.24-alpine AS build
WORKDIR /src

# No external deps: copy the module files and source, then build a static binary.
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/deploy-target .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/deploy-target /deploy-target

# Cloud Run injects $PORT (default 8080); the service reads it at startup.
ENV PORT=8080
EXPOSE 8080

USER nonroot:nonroot
ENTRYPOINT ["/deploy-target"]
