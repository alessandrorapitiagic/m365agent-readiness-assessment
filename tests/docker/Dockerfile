# Prova il bootstrap su una macchina pulita: clona la repository pubblica Microsoft (serve la rete).
# Macchina pulita: senza git, Python e pwsh, ma con curl e sudo come un normale server del cliente.
FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl sudo \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home tester \
    && echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
COPY --chown=tester:tester scripts/bootstrap_linux.sh /opt/bootstrap_linux.sh
COPY --chown=tester:tester tests/docker/test_bootstrap_linux.sh /opt/test_bootstrap_linux.sh
USER tester
WORKDIR /home/tester
ENTRYPOINT ["bash", "/opt/test_bootstrap_linux.sh"]
