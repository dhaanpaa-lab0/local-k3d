FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    vim \
    wget \
    zsh \
    && rm -rf /var/lib/apt/lists/*

# Install arkade
RUN curl -sLS https://get.arkade.dev | sh

# Install Argo CLI
ARG ARGO_VERSION=v3.7.2
ARG TARGETARCH=amd64
RUN curl -sLO "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-${TARGETARCH}.gz" && \
    gunzip "argo-linux-${TARGETARCH}.gz" && \
    chmod +x "argo-linux-${TARGETARCH}" && \
    mv "argo-linux-${TARGETARCH}" "/usr/local/bin/argo"

VOLUME [ "/h" ]