FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y \
    yq \
    jq \
    uuid \
    git-core && \
    rm -rf /var/lib/apt/lists/*
ADD ./scripts /s
VOLUME /wrk
ENTRYPOINT [ "/s/startup.sh" ]