FROM debian:bookworm-slim

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      fuse-overlayfs \
      git \
      ripgrep \
      curl \
      ca-certificates \
      nodejs \
      sudo \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/nodejs /usr/local/bin/node \
    && useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent

USER agent
WORKDIR /workspace
CMD ["sleep", "infinity"]
