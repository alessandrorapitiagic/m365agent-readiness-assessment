#!/usr/bin/env bash
# Procedura guidata: chiede tenant e servizi uno per uno (default si), poi lancia bootstrap_linux.sh --run.
# Uso nel container: ara            (guidata)
#                    ara --dry-run  (mostra solo il comando che verrebbe lanciato)
# Variabile opzionale: ARA_TENANT per saltare la domanda sul tenant.
set -Eeuo pipefail

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
fi

ask() {
    local prompt="$1" default="$2" hint answer=""
    if [[ "$default" == "y" ]]; then hint='[S/n]'; else hint='[s/N]'; fi
    read -r -p "$prompt $hint " answer || answer=""
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    [[ "$answer" == "s" || "$answer" == "si" || "$answer" == "y" || "$answer" == "yes" ]]
}

printf '%s\n' '=== Assessment M365 Copilot: procedura guidata ===' ''

tenant="${ARA_TENANT:-}"
while [[ -z "$tenant" ]]; do
    read -r -p 'Tenant del cliente (GUID o dominio, es. contoso.onmicrosoft.com): ' tenant || { printf '%s\n' 'Input terminato: tenant non indicato.' >&2; exit 2; }
    tenant="${tenant//[[:space:]]/}"
    if [[ -n "$tenant" && ! "$tenant" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ && ! "$tenant" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        printf '%s\n' 'Valore non valido: serve un GUID oppure un dominio.' >&2
        tenant=""
    fi
done

keys=(m365 entra defender power-platform copilot-studio purview a365)
names=('Microsoft 365 (licenze, Teams, SharePoint, Exchange)' 'Entra ID' 'Defender' 'Power Platform' 'Copilot Studio' 'Purview' 'Agent 365')
notes=('' '' '' 'login con codice dispositivo' 'login con codice dispositivo' 'login nel browser: nel container non e disponibile, di default si salta (c e il login sperimentale a codice dispositivo)' 'login con codice dispositivo')
defaults=(y y y y y n y)

printf '\n%s\n' 'Servizi da controllare (Invio = si, tranne dove indicato):'
selected=()
for index in "${!keys[@]}"; do
    prompt="  ${names[$index]}"
    if [[ -n "${notes[$index]}" ]]; then prompt="$prompt - ${notes[$index]}"; fi
    prompt="$prompt?"
    if ask "$prompt" "${defaults[$index]}"; then
        selected+=("${keys[$index]}")
    fi
done

if ((${#selected[@]} == 0)); then
    printf '%s\n' 'Nessun servizio selezionato: esco.'
    exit 0
fi

services_csv="$(IFS=,; printf '%s' "${selected[*]}")"
printf '\n%s\n' "Tenant:  $tenant"
printf '%s\n'   "Servizi: $services_csv"

if ! ask 'Avvio il giro completo?' y; then
    printf '%s\n' 'Annullato.'
    exit 0
fi

command=(bash /opt/bootstrap_linux.sh --run --tenant-id "$tenant" --services "$services_csv")
if ask 'Applico le correzioni al codice Microsoft (--patch)? Nel container servono per il login con codice dispositivo' y; then
    command+=(--patch)
fi
if [[ " ${selected[*]} " == *" purview "* ]] && ask 'Purview: provo il login sperimentale a codice dispositivo (--experimental-login)?' y; then
    command+=(--experimental-login)
fi
if [[ "$dry_run" == true ]]; then
    printf '%s\n' 'DRY-RUN: ' "${command[*]}"
    exit 0
fi

exec "${command[@]}"
