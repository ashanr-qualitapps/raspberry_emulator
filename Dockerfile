# Use a recent Alpine Linux as the base image
FROM alpine:3.18

# Install bash, qemu, and common utilities
RUN apk add --no-cache \
      bash \
      qemu-system \
      qemu-system-arm \
      qemu-system-aarch64 \
      qemu-img \
      ca-certificates \
      openssh-client \
      curl \
      util-linux

# Create build directory and set working dir
WORKDIR /build

# Keep container lightweight: we rely on docker-compose volumes for scripts and images
# If you need to copy files into the image at build time, uncomment the next line:
# COPY . /build

# Default entrypoint (compose overrides it)
ENTRYPOINT ["/bin/bash", "-c"]
