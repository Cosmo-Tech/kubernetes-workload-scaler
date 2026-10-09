FROM registry.cosmotech.com/proxy-chainguard/cosmotech/os-shell-iamguarded

USER root

WORKDIR /app

ENV PATH="/app:${PATH}"

COPY *.md .
COPY *.sh .

RUN chmod +x ./*.sh \
 && mv kubernetes_workload_scaler.sh kws \
 && KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt) \
 && curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x ./kubectl

# CMD ["kws"]
ENTRYPOINT ["kws"]