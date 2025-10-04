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

VOLUME [ "/h" ]