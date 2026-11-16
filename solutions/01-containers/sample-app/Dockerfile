# Reference solution for the chapter 1 lab. Try the lab on your own first.
# Build from the sample-app folder:
#   docker build --build-arg VERSION=1.0.0 -t sample-app:1.0.0 .

# Stage 1: compile the app with the Go toolchain.
FROM golang:1.27 AS build
WORKDIR /src
# go.mod first: this layer stays cached until the module definition changes.
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
# CGO_ENABLED=0 gives a static binary that needs no library from the final image.
# -s -w drops debug symbols to make the binary smaller.
RUN CGO_ENABLED=0 go build -ldflags "-s -w -X main.version=${VERSION}" -o /out/sample-app .

# Stage 2: an empty image that holds only the binary.
FROM scratch
COPY --from=build /out/sample-app /sample-app
# Numeric non-root user: there is no /etc/passwd in scratch, and Kubernetes
# can only prove that a numeric user is not root.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/sample-app"]
