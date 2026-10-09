FROM registry.cosmotech.com/proxy-chainguard/cosmotech/kubectl

WORKDIR /app
COPY * ./

RUN chmod +x ./*.sh

CMD ["", ""]