# syntax=docker/dockerfile:1.7

ARG GO_BUILDER_IMAGE=golang:1.26.4-alpine3.24
FROM ${GO_BUILDER_IMAGE} AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/full-tour-app .

FROM scratch

WORKDIR /
COPY --from=builder /out/full-tour-app /full-tour-app

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/full-tour-app"]
