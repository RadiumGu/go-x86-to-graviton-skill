FROM --platform=linux/amd64 golang:1.21 AS build
RUN curl -fsSL https://github.com/foo/bar/releases/download/v1/tool-linux-amd64 -o /tool
RUN go build -o /app ./cmd/app
FROM alpine:3.20
COPY --from=build /app /app
