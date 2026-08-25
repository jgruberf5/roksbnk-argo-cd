# Stub of ghcr.io/jgruberf5/roksbnkctl-tools-runner for exercising the Argo CD
# mechanics (phases, waves, hook Jobs, health) without IBM Cloud. Same UID/GID,
# HOME, WORKDIR and ROKSBNKCTL_HOME contract as the real runner image.
FROM alpine:3.20
ARG KUBECTL_VERSION=v1.31.4
RUN apk add --no-cache jq curl \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod 0755 /usr/local/bin/kubectl \
 && mkdir -p /work /home/runner \
 && chown -R 1000:0 /work /home/runner && chmod 0775 /work /home/runner
COPY roksbnkctl /usr/local/bin/roksbnkctl
RUN chmod 0755 /usr/local/bin/roksbnkctl
USER 1000
ENV ROKSBNKCTL_HOME=/work/.roksbnkctl HOME=/home/runner
WORKDIR /work
ENTRYPOINT ["roksbnkctl"]
