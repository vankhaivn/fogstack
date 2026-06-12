ARG TOOLBOX_BASE_IMAGE=debian:bookworm-slim
FROM ${TOOLBOX_BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TERRAFORM_VERSION=1.14.8
ARG KUBECTL_CLIENT_VERSION=v1.32.7
ARG HELM_VERSION=v4.1.3
ARG KIND_VERSION=v0.31.0
ARG AWS_CLI_VERSION=2.34.20
ARG DOCKER_CLI_VERSION=29.1.3
ARG POSTGRES_CLIENT_MAJOR=16
ARG SHELLCHECK_VERSION=0.11.0
ARG HADOLINT_VERSION=v2.14.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    gnupg \
    gzip \
    less \
    groff \
    tar \
    unzip \
    xz-utils \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg \
  && . /etc/os-release \
  && printf 'deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "${VERSION_CODENAME}" \
    > /etc/apt/sources.list.d/postgresql.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends "postgresql-client-${POSTGRES_CLIENT_MAJOR}" \
  && rm -rf /var/lib/apt/lists/*

RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "${arch}" in \
    amd64) terraform_arch="amd64"; kubectl_arch="amd64"; helm_arch="amd64"; kind_arch="amd64"; aws_arch="x86_64"; docker_arch="x86_64"; hadolint_arch="x86_64" ;; \
    arm64) terraform_arch="arm64"; kubectl_arch="arm64"; helm_arch="arm64"; kind_arch="arm64"; aws_arch="aarch64"; docker_arch="aarch64"; hadolint_arch="arm64" ;; \
    *) printf 'unsupported architecture: %s\n' "${arch}" >&2; exit 1 ;; \
  esac \
  && curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${terraform_arch}.zip" \
  && unzip -q /tmp/terraform.zip -d /usr/local/bin \
  && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_CLIENT_VERSION}/bin/linux/${kubectl_arch}/kubectl" \
  && chmod 0755 /usr/local/bin/kubectl \
  && curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz" \
  && tar -xzf /tmp/helm.tgz -C /tmp \
  && mv "/tmp/linux-${helm_arch}/helm" /usr/local/bin/helm \
  && chmod 0755 /usr/local/bin/helm \
  && curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${kind_arch}" \
  && chmod 0755 /usr/local/bin/kind \
  && curl -fsSLo /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip" \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
  && curl -fsSLo /tmp/docker.tgz "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
  && tar -xzf /tmp/docker.tgz -C /tmp \
  && mv /tmp/docker/docker /usr/local/bin/docker \
  && chmod 0755 /usr/local/bin/docker \
  && curl -fsSLo /tmp/shellcheck.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${docker_arch}.tar.xz" \
  && tar -xJf /tmp/shellcheck.tar.xz -C /tmp \
  && mv "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
  && chmod 0755 /usr/local/bin/shellcheck \
  && curl -fsSLo /usr/local/bin/hadolint "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-${hadolint_arch}" \
  && chmod 0755 /usr/local/bin/hadolint \
  && rm -rf /tmp/*

RUN terraform version \
  && kubectl version --client=true \
  && helm version --short \
  && kind version \
  && aws --version \
  && psql --version \
  && shellcheck --version \
  && hadolint --version \
  && docker --version

WORKDIR /workspace

CMD ["bash"]
