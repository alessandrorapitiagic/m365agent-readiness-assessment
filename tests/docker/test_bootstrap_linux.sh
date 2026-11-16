#!/usr/bin/env bash
# Eseguito dentro il container (macchina pulita): prova bootstrap_linux.sh dall'inizio alla fine,
# clonando la repository pubblica Microsoft.
# ARA_TEST_SCRIPT_URL: usa lo script pubblicato invece del file locale.
# ARA_TEST_SKIP_MODULES=1: salta l'installazione reale di PowerShell e dei moduli (la parte piu lenta).
set -Eeuo pipefail

install_dir="$HOME/m365-ara"
failures=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'OK   %s\n' "$description"
    else
        printf 'FAIL %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

check_fails() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL %s\n' "$description" >&2
        failures=$((failures + 1))
    else
        printf 'OK   %s\n' "$description"
    fi
}

if [[ -n "${ARA_TEST_SCRIPT_URL:-}" ]]; then
    run_bootstrap() { curl -fsSL "$ARA_TEST_SCRIPT_URL" | bash -s -- "$@"; }
else
    run_bootstrap() { bash /opt/bootstrap_linux.sh "$@"; }
fi

printf '%s\n' '--- Macchina pulita ---'
check_fails 'git assente all avvio' command -v git
check_fails 'python3 assente all avvio' command -v python3
check_fails 'pwsh assente all avvio' command -v pwsh

printf '%s\n' '--- 1. Installazione pulita (servizi solo Python) ---'
run_bootstrap --dir "$install_dir" --services m365,entra,defender
check 'git installato' command -v git
check 'python3 installato' python3 --version
check 'repository clonata (main.py)' test -f "$install_dir/main.py"
check 'repository git (.git)' test -d "$install_dir/.git"
check 'ambiente .venv creato' test -x "$install_dir/.venv/bin/python"
check 'dipendenze Python importabili' "$install_dir/.venv/bin/python" -c 'import azure.identity, msgraph, httpx, openpyxl'
check_fails 'pwsh non installato senza servizi PowerShell' command -v pwsh
check_fails 'di default il codice Microsoft resta originale' grep -q 'get_teams_user_activity_counts_with_period' "$install_dir/Recommendations/m365/TEAMS1.py"

printf '%s\n' '--- 1b. --patch applica le correzioni e spiega il perche ---'
output="$(run_bootstrap --dir "$install_dir" --services m365,entra,defender --patch 2>&1)"
check 'correzioni applicate con --patch' grep -q 'get_teams_user_activity_counts_with_period' "$install_dir/Recommendations/m365/TEAMS1.py"
check 'il messaggio spiega il perche delle correzioni' grep -q 'Perche' <<<"$output"
check 'correzione del login con codice dispositivo' grep -q 'UseDeviceAuthentication' "$install_dir/setup-service-principal.ps1"

printf '%s\n' '--- 2. Seconda esecuzione: aggiornamento senza perdere i dati del cliente ---'
printf 'TENANT_ID=test\n' > "$install_dir/.env"
mkdir -p "$install_dir/Reports"
printf 'x\n' > "$install_dir/Reports/keep.csv"
run_bootstrap --dir "$install_dir" --services all --check-only
run_bootstrap --dir "$install_dir" --services m365 --patch
check '.env conservato' grep -q 'TENANT_ID=test' "$install_dir/.env"
check 'Reports conservato' test -f "$install_dir/Reports/keep.csv"
check 'correzioni ancora applicate dopo l aggiornamento con --patch' grep -q 'get_teams_user_activity_counts_with_period' "$install_dir/Recommendations/m365/TEAMS1.py"

printf '%s\n' '--- 2b. Senza --patch il codice torna originale; --patch lo corregge di nuovo ---'
run_bootstrap --dir "$install_dir" --services m365
check_fails 'senza --patch il codice Microsoft torna originale' grep -q 'get_teams_user_activity_counts_with_period' "$install_dir/Recommendations/m365/TEAMS1.py"
check 'repository pulita dopo il ripristino' bash -c "test -z \"\$(git -C '$install_dir' status --porcelain --untracked-files=no)\""
run_bootstrap --dir "$install_dir" --services m365 --patch
check 'correzioni riapplicate con --patch' grep -q 'get_teams_user_activity_counts_with_period' "$install_dir/Recommendations/m365/TEAMS1.py"

printf '%s\n' '--- 3. --check-only non modifica nulla ---'
output="$(run_bootstrap --dir "$install_dir" --check-only --services purview 2>&1)"
check 'check-only segnala pwsh mancante' grep -q 'MANCANTE.*pwsh' <<<"$output"
check_fails 'check-only non installa pwsh' command -v pwsh

printf '%s\n' '--- 3b. Controllo del consenso amministrativo ---'
output="$(run_bootstrap --dir "$install_dir" --check-consent 2>&1 || true)"
check 'consenso: credenziali incomplete segnalate' grep -q 'credenziali incomplete' <<<"$output"

# Simula un'app senza permessi: l'interprete del venv risponde MISSING agli script di controllo.
printf 'TENANT_ID=11111111-1111-1111-1111-111111111111\nCLIENT_ID=22222222-2222-2222-2222-222222222222\nCLIENT_SECRET=x\n' > "$install_dir/.env"
venv_bin="$install_dir/.venv/bin"
mv "$venv_bin/python" "$venv_bin/python.real"
cat > "$venv_bin/python" <<'WRAP'
#!/usr/bin/env bash
if [[ "${1:-}" != -* ]]; then echo "MISSING:Reports.Read.All"; exit 0; fi
exec "$(dirname "$0")/python.real" "$@"
WRAP
chmod +x "$venv_bin/python"
output="$(ARA_CONSENT_POLL_SECONDS=1 ARA_CONSENT_MAX_POLLS=2 run_bootstrap --dir "$install_dir" --check-consent 2>&1 || true)"
check 'consenso mancante: mostra il link di consenso' grep -q 'adminconsent?client_id=22222222' <<<"$output"
check 'consenso mancante: elenca i permessi' grep -q 'Reports.Read.All' <<<"$output"
check 'consenso mancante: termina con errore' grep -q 'consenso non rilevato' <<<"$output"
rm "$venv_bin/python"
mv "$venv_bin/python.real" "$venv_bin/python"

printf '%s\n' '--- 4. Validazione parametri ---'
check_fails 'opzione sconosciuta rifiutata' run_bootstrap --opzione-inesistente
check_fails 'servizio sconosciuto rifiutato' run_bootstrap --dir "$install_dir" --services inesistente
check_fails 'cartella non-git rifiutata' bash -c "mkdir -p /tmp/occupata && touch /tmp/occupata/file && bash /opt/bootstrap_linux.sh --dir /tmp/occupata"
check_fails '--run senza tenant rifiutato (nessun terminale)' run_bootstrap --dir "$install_dir" --run
check_fails 'pwsh ancora assente dopo --run rifiutato' command -v pwsh

if [[ "${ARA_TEST_SKIP_MODULES:-0}" != "1" ]]; then
    printf '%s\n' '--- 5. PowerShell e modulo Purview (installazione reale) ---'
    run_bootstrap --dir "$install_dir" --services purview
    export PATH="$HOME/.local/bin:$PATH"
    check 'pwsh funzionante' pwsh -NoProfile -Command 'exit 0'
    check 'modulo ExchangeOnlineManagement installato' pwsh -NoProfile -Command 'if (Get-Module -ListAvailable -Name ExchangeOnlineManagement) { exit 0 } else { exit 1 }'
    run_bootstrap --dir "$install_dir" --services purview --check-only
fi

if ((failures > 0)); then
    printf '\n%d verifiche fallite.\n' "$failures" >&2
    exit 1
fi
printf '\n%s\n' 'Tutte le verifiche sono passate.'
