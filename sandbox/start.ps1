# Avvia la sandbox (la costruisce al primo uso) e apre la procedura guidata nel container.
#   .\sandbox\start.ps1          procedura guidata: tenant, servizi uno per uno, poi il giro completo
#   .\sandbox\start.ps1 -Shell   shell nel container, per lanciare i comandi a mano
[CmdletBinding()]
param([switch]$Shell)

$ErrorActionPreference = "Stop"
$compose = Join-Path $PSScriptRoot "docker-compose.yml"

& docker compose -f $compose up -d --build
if ($LASTEXITCODE -ne 0) { throw "Avvio della sandbox non riuscito. Verifica che Docker Desktop sia in esecuzione." }

if ($Shell) { & docker exec -it ara-sandbox bash }
else { & docker exec -it ara-sandbox ara }
