# Sandbox per l'assessment: macchina Linux pulita con git, Python, PowerShell, moduli e repository Microsoft
# gia' installati dal bootstrap. Si entra con "docker exec -it ara-sandbox ara" (vedi sandbox/start.ps1).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PYTHONIOENCODING=utf-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl sudo less nano \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash ara \
    && echo 'ara ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ara

COPY --chown=ara:ara scripts/bootstrap_linux.sh /opt/bootstrap_linux.sh
COPY sandbox/ara-wizard.sh /usr/local/bin/ara
RUN chmod +x /usr/local/bin/ara

USER ara
WORKDIR /home/ara
ENV PATH="/home/ara/.local/bin:${PATH}"

# Installa tutto in fase di build: all'avvio il bootstrap trova gli strumenti e si limita ad aggiornare.
RUN bash /opt/bootstrap_linux.sh --services all --include-setup-module

CMD ["sleep", "infinity"]
