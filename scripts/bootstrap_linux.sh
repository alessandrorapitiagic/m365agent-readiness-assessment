#!/usr/bin/env bash
# Standalone: non servono altri file. Controlla (e se manca installa) git, Python 3.8+ con venv e,
# se servono moduli PowerShell, PowerShell 7; poi clona la repository ARA e prepara l'ambiente.
# Esempio:
#   curl -fsSL https://raw.githubusercontent.com/alessandrorapitiagic/m365agent-readiness-assessment/main/scripts/bootstrap_linux.sh | bash -s -- --services purview,a365
#
# Di default il codice Microsoft resta quello originale. Con --patch si applicano le correzioni descritte nel README.
set -Eeuo pipefail

default_repo_url="https://github.com/microsoft/m365-copilot-automated-readiness-assessment.git"

usage() {
    printf '%s\n' \
        'Uso: bash bootstrap_linux.sh [opzioni]' \
        '' \
        'Opzioni:' \
        '  --dir PERCORSO          Cartella di destinazione (default: $HOME/m365-ara)' \
        '  --branch NOME           Branch da clonare (default: main)' \
        '  --repo-url URL          Repository git da clonare (default: repository Microsoft)' \
        '  --services ELENCO       Servizi da analizzare, separati da virgola:' \
        '                          m365,entra,defender,power-platform,copilot-studio,purview,a365,all' \
        '  --include-setup-module  Installa Microsoft.Graph per setup-service-principal.ps1' \
        '  --run                   Al termine avvia main.py: se manca .env parte il login (serve un Global Administrator)' \
        '  --tenant-id TENANT      Tenant del cliente (GUID o dominio), obbligatorio con --run' \
        '  --check-consent         Verifica solo il consenso amministrativo dell app e termina' \
        '  --check-only            Verifica i prerequisiti senza modificare nulla' \
        '  --patch                 Applica le correzioni al codice Microsoft (vedi print_upstream_fix_patch); senza, il codice resta originale' \
        '  -h, --help              Mostra questo messaggio'
}

install_dir="$HOME/m365-ara"
branch="main"
repo_url="${ARA_REPOSITORY_URL:-$default_repo_url}"
services_csv=""
include_setup_module=false
check_only=false
run_after=false
check_consent=false
apply_patch=false
tenant_id=""

while (($# > 0)); do
    case "$1" in
        --dir|--branch|--repo-url|--services|--tenant-id)
            if (($# < 2)); then
                printf 'Errore: %s richiede un valore.\n' "$1" >&2
                exit 2
            fi
            case "$1" in
                --dir) install_dir="$2" ;;
                --branch) branch="$2" ;;
                --repo-url) repo_url="$2" ;;
                --services) services_csv="$2" ;;
                --tenant-id) tenant_id="$2" ;;
            esac
            shift 2
            ;;
        --run)
            run_after=true
            shift
            ;;
        --check-consent)
            check_consent=true
            shift
            ;;
        --include-setup-module)
            include_setup_module=true
            shift
            ;;
        --check-only)
            check_only=true
            shift
            ;;
        --patch)
            apply_patch=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Opzione non riconosciuta: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

declare -a module_names=()
declare -a module_checks=()
needs_gh=false
needs_pp=false

add_module() {
    local name="$1"
    local check_name="$2"
    local existing

    for existing in ${module_names[@]+"${module_names[@]}"}; do
        if [[ "$existing" == "$name" ]]; then
            return
        fi
    done

    module_names+=("$name")
    module_checks+=("$check_name")
}

# m365, entra e defender usano solo Python: non richiedono moduli PowerShell.
declare -a requested_services=()
declare -a analyze_services=()
analyze_all=false
if [[ -n "$services_csv" ]]; then
    IFS=',' read -r -a requested_services <<< "$services_csv"
else
    analyze_all=true
fi

for service in ${requested_services[@]+"${requested_services[@]}"}; do
    service="${service,,}"
    case "$service" in
        m365)
            analyze_services+=('M365')
            ;;
        entra)
            analyze_services+=('Entra')
            ;;
        defender)
            analyze_services+=('Defender')
            ;;
        '')
            ;;
        power-platform)
            analyze_services+=('Power Platform')
            add_module 'Az' 'Az.Accounts'
            needs_pp=true
            ;;
        copilot-studio)
            analyze_services+=('Copilot Studio')
            add_module 'Az' 'Az.Accounts'
            needs_pp=true
            ;;
        purview)
            analyze_services+=('Purview')
            add_module 'ExchangeOnlineManagement' 'ExchangeOnlineManagement'
            ;;
        a365)
            analyze_services+=('A365')
            add_module 'Microsoft.Graph' 'Microsoft.Graph.Authentication'
            needs_gh=true
            ;;
        all)
            analyze_all=true
            needs_gh=true
            needs_pp=true
            add_module 'Az' 'Az.Accounts'
            add_module 'ExchangeOnlineManagement' 'ExchangeOnlineManagement'
            add_module 'Microsoft.Graph' 'Microsoft.Graph.Authentication'
            ;;
        *)
            printf 'Servizio non valido: %s\n' "$service" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$run_after" == true ]]; then
    # Il login iniziale usa Microsoft.Graph; senza --services si analizza tutto, quindi servono tutti i moduli.
    include_setup_module=true
    if [[ -z "$services_csv" ]]; then
        add_module 'Az' 'Az.Accounts'
        add_module 'ExchangeOnlineManagement' 'ExchangeOnlineManagement'
        needs_gh=true
        needs_pp=true
    fi
fi

if [[ "$include_setup_module" == true ]]; then
    add_module 'Microsoft.Graph' 'Microsoft.Graph.Authentication'
fi

work_dir=""
trap 'if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi' EXIT

fail() {
    printf 'Errore: %s\n' "$1" >&2
    exit 1
}

python_ok() {
    command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

pwsh_ok() {
    command -v pwsh >/dev/null 2>&1 && pwsh -NoProfile -Command 'exit 0' >/dev/null 2>&1
}

print_status() {
    if [[ "$2" == true ]]; then
        printf '[OK]       %s\n' "$1"
    else
        printf '[MANCANTE] %s\n' "$1"
    fi
}

pkg_manager=""
for candidate in apt-get dnf yum; do
    if command -v "$candidate" >/dev/null 2>&1; then
        pkg_manager="$candidate"
        break
    fi
done

run_privileged() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "servono privilegi di root (o sudo) per eseguire: $*"
    fi
}

install_system_packages() {
    [[ -n "$pkg_manager" ]] || fail 'gestore pacchetti non supportato: installa manualmente git, Python 3.8+ con venv e pwsh.'
    printf 'Installo i pacchetti di sistema: %s\n' "$*"
    if [[ "$pkg_manager" == "apt-get" ]]; then
        run_privileged apt-get update
        run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    else
        run_privileged "$pkg_manager" install -y "$@"
    fi
}

ensure_git_and_python() {
    local -a packages=()

    if ! command -v git >/dev/null 2>&1; then
        packages+=(git ca-certificates)
    fi
    if ! python_ok; then
        if [[ "$pkg_manager" == "apt-get" ]]; then
            packages+=(python3 python3-pip python3-venv)
        else
            packages+=(python3 python3-pip)
        fi
    fi

    if ((${#packages[@]} > 0)); then
        install_system_packages "${packages[@]}"
    fi

    command -v git >/dev/null 2>&1 || fail 'git non disponibile dopo l installazione.'
    python_ok || fail 'Python 3.8 o successivo con venv non disponibile dopo l installazione.'
}

install_pwsh() {
    local arch
    case "$(uname -m)" in
        x86_64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) fail "architettura non supportata per PowerShell: $(uname -m)" ;;
    esac

    local -a packages=(curl tar ca-certificates)
    if ! ldconfig -p 2>/dev/null | grep -q 'libicuuc'; then
        if [[ "$pkg_manager" == "apt-get" ]]; then
            local icu_package
            icu_package="$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n1)"
            packages+=("${icu_package:-libicu-dev}")
        else
            packages+=(libicu)
        fi
    fi
    install_system_packages "${packages[@]}"

    work_dir="$(mktemp -d)"

    # Il redirect di /releases/latest evita le API GitHub, soggette a rate limit senza autenticazione.
    local latest_url version base_url archive
    latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' 'https://github.com/PowerShell/PowerShell/releases/latest')"
    version="${latest_url##*/v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "versione di PowerShell non riconosciuta: $latest_url"
    base_url="https://github.com/PowerShell/PowerShell/releases/download/v${version}"
    archive="powershell-${version}-linux-${arch}.tar.gz"

    printf 'Scarico PowerShell %s...\n' "$version"
    curl -fsSL "$base_url/$archive" -o "$work_dir/$archive"
    curl -fsSL "$base_url/hashes.sha256" -o "$work_dir/hashes.sha256"

    local expected actual
    # hashes.sha256 e pubblicato in UTF-16: tr elimina i byte nulli e i ritorni a capo.
    expected="$(tr -d '\000\r' < "$work_dir/hashes.sha256" | grep -a -F "$archive" | awk '{print tolower($1)}' | head -n1 || true)"
    actual="$(sha256sum "$work_dir/$archive" | awk '{print tolower($1)}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || fail 'checksum di PowerShell non valido: installazione annullata.'

    local target="$HOME/.local/share/powershell"
    rm -rf "$target"
    mkdir -p "$target" "$HOME/.local/bin"
    tar -xzf "$work_dir/$archive" -C "$target"
    chmod +x "$target/pwsh"
    ln -sf "$target/pwsh" "$HOME/.local/bin/pwsh"
    export PATH="$HOME/.local/bin:$PATH"
}

install_gh() {
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) fail "architettura non supportata per GitHub CLI: $(uname -m)" ;;
    esac

    install_system_packages curl tar ca-certificates
    work_dir="${work_dir:-$(mktemp -d)}"

    local latest_url version base_url archive dir
    latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' 'https://github.com/cli/cli/releases/latest')"
    version="${latest_url##*/v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "versione di GitHub CLI non riconosciuta: $latest_url"
    base_url="https://github.com/cli/cli/releases/download/v${version}"
    dir="gh_${version}_linux_${arch}"
    archive="${dir}.tar.gz"

    printf 'Scarico GitHub CLI %s...\n' "$version"
    curl -fsSL "$base_url/$archive" -o "$work_dir/$archive"
    curl -fsSL "$base_url/gh_${version}_checksums.txt" -o "$work_dir/gh_checksums.txt"

    local expected actual
    expected="$(grep -F "$archive" "$work_dir/gh_checksums.txt" | awk '{print tolower($1)}' | head -n1 || true)"
    actual="$(sha256sum "$work_dir/$archive" | awk '{print tolower($1)}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || fail 'checksum di GitHub CLI non valido: installazione annullata.'

    local target="$HOME/.local/share/gh"
    rm -rf "$target"
    mkdir -p "$target" "$HOME/.local/bin"
    tar -xzf "$work_dir/$archive" -C "$target" --strip-components=1
    chmod +x "$target/bin/gh"
    ln -sf "$target/bin/gh" "$HOME/.local/bin/gh"
    export PATH="$HOME/.local/bin:$PATH"
}

# Il codice si scarica solo dalla repository pubblica Microsoft. Con --patch si applica una piccola patch
# (6 file) che corregge difetti: il codice Microsoft legge il report degli utenti attivi con
# le colonne di un altro report e usa chiavi mai definite, quindi molti indicatori M365 risultano 0 anche se il
# tenant ha attivita; 4 raccomandazioni chiamano metodi Graph inesistenti; lo script di setup apre il login nel
# browser, che fallisce su server o sessioni remote, e passa al codice dispositivo. La patch si applica solo se il
# codice scaricato e quello atteso, altrimenti viene saltata con un avviso.
print_upstream_fix_patch() {
    cat <<'UPSTREAM_FIX_PATCH'
diff --git a/Core/get_m365_client.py b/Core/get_m365_client.py
index e045b09..28f325f 100644
--- a/Core/get_m365_client.py
+++ b/Core/get_m365_client.py
@@ -383,20 +383,28 @@ async def get_m365_client(graph_client):
             if parsed_rows:
                 client.available = True
-                # Extract latest row (most recent date) for current snapshot
-                if parsed_rows:
-                    latest_row = parsed_rows[-1]  # CSV is sorted by date, last row is most recent
-                    
-                    client.active_users_summary = {
-                        'available': True,
-                        'report_period': report_period,
-                        'office_365_active': int(latest_row.get('Office 365', 0) or 0),
-                        'exchange_active': int(latest_row.get('Exchange', 0) or 0),
-                        'onedrive_active': int(latest_row.get('OneDrive', 0) or 0),
-                        'sharepoint_active': int(latest_row.get('SharePoint', 0) or 0),
-                        'teams_active': int(latest_row.get('Microsoft Teams', 0) or 0),
-                        'yammer_active': int(latest_row.get('Yammer', 0) or 0)
-                    }
-                else:
-                    client.active_users_summary = {'available': False, 'error': 'No rows in report'}
+                # getOffice365ActiveUserDetail returns one row per user: a service is active if its last-activity date is set
+                service_columns = {
+                    'exchange_active': 'Exchange Last Activity Date',
+                    'onedrive_active': 'OneDrive Last Activity Date',
+                    'sharepoint_active': 'SharePoint Last Activity Date',
+                    'teams_active': 'Teams Last Activity Date',
+                    'yammer_active': 'Yammer Last Activity Date'
+                }
+                activity_columns = list(service_columns.values()) + ['Skype For Business Last Activity Date']
+
+                active_users_summary = {key: 0 for key in service_columns}
+                active_users_summary['office_365_active'] = 0
+                for row in parsed_rows:
+                    for key, column in service_columns.items():
+                        if row.get(column):
+                            active_users_summary[key] += 1
+                    if any(row.get(column) for column in activity_columns):
+                        active_users_summary['office_365_active'] += 1
+
+                client.active_users_summary = {
+                    'available': True,
+                    'report_period': report_period,
+                    **active_users_summary
+                }
             else:
                 client.active_users_summary = {'available': False, 'error': 'No data in report'}
@@ -510,7 +518,10 @@ def extract_m365_insights_from_client(m365_client):
         'sharepoint_report_available': sharepoint_summary.get('available', False),
         'sharepoint_report_period': sharepoint_summary.get('report_period', 'D30'),
+        'sharepoint_total_sites': sharepoint_summary.get('sites_in_report', 0),
         'sharepoint_active_sites': sharepoint_summary.get('active_sites', 0),
         'sharepoint_total_files': sharepoint_summary.get('total_files', 0),
+        'total_files': sharepoint_summary.get('total_files', 0),
         'sharepoint_total_page_views': sharepoint_summary.get('total_page_views', 0),
+        'sharepoint_page_views': sharepoint_summary.get('total_page_views', 0),
         'sharepoint_activity_rate': sharepoint_summary.get('site_activity_rate', 0),
         'sharepoint_avg_files_per_site': sharepoint_summary.get('avg_files_per_site', 0),
@@ -567,4 +578,7 @@ def extract_m365_insights_from_client(m365_client):
         'active_users_report_period': active_users_summary.get('report_period', 'D30'),
         'office365_active_users': active_users_summary.get('office_365_active', 0),
+        # Names read by the Recommendations modules
+        'total_active_users': active_users_summary.get('office_365_active', 0),
+        'office_active_users': active_users_summary.get('office_365_active', 0),
         'exchange_active_users': active_users_summary.get('exchange_active', 0),
         'teams_active_users_snapshot': active_users_summary.get('teams_active', 0),
diff --git a/Recommendations/copilot_studio/POWER_VIRTUAL_AGENTS_O365_P3.py b/Recommendations/copilot_studio/POWER_VIRTUAL_AGENTS_O365_P3.py
index ee60361..85a3a44 100644
--- a/Recommendations/copilot_studio/POWER_VIRTUAL_AGENTS_O365_P3.py
+++ b/Recommendations/copilot_studio/POWER_VIRTUAL_AGENTS_O365_P3.py
@@ -5,12 +5,16 @@ from Core.new_recommendation import new_recommendation
 from Core.friendly_names import get_friendly_sku_name
 from Core.get_power_platform_client import extract_pp_insights_from_client
+import csv
+import io
 
 async def get_deployment_status(client, pp_insights=None):
     """Check Teams availability for agent deployment with environment awareness."""
     try:
-        teams_activity = await client.reports.get_teams_user_activity_counts(period='D7').get()
+        teams_activity = await client.reports.get_teams_user_activity_counts_with_period(period='D7').get()
+        # Il report e' un CSV in bytes: una riga per giorno con attivita'.
+        rows = list(csv.DictReader(io.StringIO(teams_activity.decode('utf-8-sig')))) if isinstance(teams_activity, bytes) else []
         result = {
             'available': True,
-            'has_teams': teams_activity and teams_activity.value and len(teams_activity.value) > 0
+            'has_teams': len(rows) > 0
         }
         
diff --git a/Recommendations/copilot_studio/VIRTUAL_AGENT_BASE_MESSAGES.py b/Recommendations/copilot_studio/VIRTUAL_AGENT_BASE_MESSAGES.py
index 5bd85aa..0329a15 100644
--- a/Recommendations/copilot_studio/VIRTUAL_AGENT_BASE_MESSAGES.py
+++ b/Recommendations/copilot_studio/VIRTUAL_AGENT_BASE_MESSAGES.py
@@ -4,4 +4,6 @@ Power Virtual Agents (Base) - Copilot Studio & Agent Adoption Recommendation
 from Core.new_recommendation import new_recommendation
 from Core.friendly_names import get_friendly_sku_name
+import csv
+import io
 
 async def get_deployment_status(client):
@@ -10,11 +12,10 @@ async def get_deployment_status(client):
     """
     try:
-        teams_activity = await client.reports.get_teams_user_activity_counts(period='D30').get()
-        
-        if teams_activity and teams_activity.value:
-            total_messages = 0
-            for row in teams_activity.value:
-                if hasattr(row, 'team_chat_messages'):
-                    total_messages += int(row.team_chat_messages or 0)
+        teams_activity = await client.reports.get_teams_user_activity_counts_with_period(period='D30').get()
+        # Il report e' un CSV in bytes: una riga per giorno con i totali di attivita'.
+        rows = list(csv.DictReader(io.StringIO(teams_activity.decode('utf-8-sig')))) if isinstance(teams_activity, bytes) else []
+
+        if rows:
+            total_messages = sum(int(row.get('Team Chat Messages', 0) or 0) for row in rows)
             
             return {
diff --git a/Recommendations/m365/EXCHANGE_S_ENTERPRISE.py b/Recommendations/m365/EXCHANGE_S_ENTERPRISE.py
index 2374ca4..1904f97 100644
--- a/Recommendations/m365/EXCHANGE_S_ENTERPRISE.py
+++ b/Recommendations/m365/EXCHANGE_S_ENTERPRISE.py
@@ -105,5 +105,5 @@ async def get_deployment_status(client):
         
         # Get email activity details
-        activity_response = await client.reports.get_email_activity_counts(period=period).get()
+        activity_response = await client.reports.get_email_activity_counts_with_period(period=period).get()
         
         # Parse the response to get activity metrics
diff --git a/Recommendations/m365/TEAMS1.py b/Recommendations/m365/TEAMS1.py
index c3aebf6..60e4aca 100644
--- a/Recommendations/m365/TEAMS1.py
+++ b/Recommendations/m365/TEAMS1.py
@@ -17,5 +17,5 @@ async def get_deployment_status(client):
         
         # Get Teams activity details - this returns aggregated data
-        activity_response = await client.reports.get_teams_user_activity_counts(period=period).get()
+        activity_response = await client.reports.get_teams_user_activity_counts_with_period(period=period).get()
         
         # Parse the CSV response to get activity metrics
diff --git a/setup-service-principal.ps1 b/setup-service-principal.ps1
--- a/setup-service-principal.ps1
+++ b/setup-service-principal.ps1
@@ -65,7 +65,7 @@
 Write-Info "Connecting to Microsoft Graph..."
-Write-Info "Browser will open for authentication (requires Global Admin)"
+Write-Info "Complete the device-code sign-in shown in this terminal (requires Global Admin)"
 
 try {
     # Use Process scope to maintain authentication context throughout script
-    Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.Read.All", "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All" -ContextScope Process -NoWelcome -ErrorAction Stop
+    Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.Read.All", "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All" -ContextScope Process -UseDeviceAuthentication -NoWelcome -ErrorAction Stop
     $context = Get-MgContext
UPSTREAM_FIX_PATCH
}

upstream_fix_files() {
    print_upstream_fix_patch | sed -n 's#^diff --git a/\([^ ]*\) .*#\1#p'
}

# Riporta i file della patch allo stato originale, cosi il pull non trova modifiche locali.
reset_upstream_fixes() {
    local file
    while IFS= read -r file; do
        git -C "$install_dir" checkout -- "$file" 2>/dev/null || true
    done < <(upstream_fix_files)
}

apply_upstream_fixes() {
    local patch_file files count
    patch_file="$(mktemp)"
    print_upstream_fix_patch > "$patch_file"
    files="$(upstream_fix_files | paste -sd, - | sed 's/,/, /g')"
    count="$(upstream_fix_files | wc -l)"

    if git -C "$install_dir" apply --check --ignore-whitespace "$patch_file" 2>/dev/null; then
        printf '%s\n' \
            "Applico $count correzioni al codice Microsoft. Perche:" \
            '  - legge il report degli utenti attivi con le colonne di un altro report e usa chiavi mai definite: molti indicatori M365 risultano 0 (es. 0 active users) anche se il tenant ha attivita.' \
            '  - 4 raccomandazioni (Teams, Exchange, Power Virtual Agents) chiamano metodi Graph inesistenti e non producono dati.' \
            '  - lo script di setup apre il login nel browser: su server o sessioni remote fallisce (Authentication failed or was cancelled). Si usa il codice dispositivo.' \
            "  Si modificano solo questi file: $files."
        git -C "$install_dir" apply --ignore-whitespace "$patch_file" \
            || printf '%s\n' 'Attenzione: applicazione delle correzioni non riuscita: il report puo contenere indicatori a 0 non reali.' >&2
    elif git -C "$install_dir" apply --reverse --check --ignore-whitespace "$patch_file" 2>/dev/null; then
        printf '%s\n' 'Correzioni al codice Microsoft gia presenti.'
    else
        printf '%s\n' 'Attenzione: il codice Microsoft e cambiato rispetto a quello atteso: correzioni NON applicate. Il report puo contenere indicatori a 0 non reali.' >&2
    fi
    rm -f "$patch_file"
}

required_consent_roles="Reports.Read.All,User.Read.All,Sites.Read.All,Policy.Read.All,AuditLog.Read.All,Directory.Read.All"

env_file_value() {
    local value
    value="$(grep -m1 "^$2=" "$1" || true)"
    value="${value#*=}"
    value="${value%\"}"
    printf '%s' "${value#\"}"
}

# Stampa OK, MISSING:<permessi> oppure ERROR:<dettaglio>.
test_app_consent() {
    local python_exe="$1" env_file="$2" script output line
    script="$(mktemp)"
    cat > "$script" <<'PY'
import base64
import json
import sys


def main():
    env_file = sys.argv[1]
    required = [role for role in sys.argv[2].split(",") if role]
    env = {}
    with open(env_file, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('"').strip("'")
    try:
        from azure.identity import ClientSecretCredential
        credential = ClientSecretCredential(env["TENANT_ID"], env["CLIENT_ID"], env["CLIENT_SECRET"])
        token = credential.get_token("https://graph.microsoft.com/.default").token
    except KeyError as error:
        print("ERROR:credenziali incomplete nel file .env (manca %s)" % error)
        return
    except Exception as error:
        first_line = (str(error).splitlines() or [""])[0][:200]
        print("ERROR:autenticazione non riuscita: %s" % first_line)
        return
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    roles = set(json.loads(base64.urlsafe_b64decode(payload)).get("roles", []))
    missing = [role for role in required if role not in roles]
    print(("MISSING:" + ",".join(missing)) if missing else "OK")


main()
PY
    output="$("$python_exe" "$script" "$env_file" "$required_consent_roles" 2>/dev/null || true)"
    rm -f "$script"
    line="$(printf '%s\n' "$output" | grep -E '^(OK$|MISSING:|ERROR:)' | tail -n1 || true)"
    printf '%s' "${line:-ERROR:risposta inattesa dal controllo}"
}

# ARA_CONSENT_POLL_SECONDS e ARA_CONSENT_MAX_POLLS servono ai test per accorciare l attesa.
confirm_admin_consent() {
    local python_exe="$1" env_file="$2" result="" attempt poll tenant client url
    local poll_seconds="${ARA_CONSENT_POLL_SECONDS:-10}" max_polls="${ARA_CONSENT_MAX_POLLS:-30}"

    for attempt in 1 2 3 4; do
        result="$(test_app_consent "$python_exe" "$env_file")"
        if [[ "$result" != ERROR:* ]]; then
            break
        fi
        if ((attempt < 4)); then
            sleep "$poll_seconds"
        fi
    done
    if [[ "$result" == ERROR:* ]]; then
        fail "impossibile verificare il consenso dell app: ${result#ERROR:}"
    fi
    if [[ "$result" == "OK" ]]; then
        printf '%s\n' 'Consenso amministrativo verificato: i permessi dell app sono concessi.'
        return 0
    fi

    tenant="$(env_file_value "$env_file" TENANT_ID)"
    client="$(env_file_value "$env_file" CLIENT_ID)"
    url="https://login.microsoftonline.com/${tenant}/adminconsent?client_id=${client}"
    printf 'Mancano permessi concessi all app: %s\n' "${result#MISSING:}"
    printf 'Un Global Administrator del tenant deve accettare qui: %s\n' "$url"
    if command -v xdg-open >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        xdg-open "$url" >/dev/null 2>&1 || true
    fi
    printf '%s\n' 'Attendo il consenso (fino a 5 minuti)...'
    for ((poll = 0; poll < max_polls; poll++)); do
        sleep "$poll_seconds"
        result="$(test_app_consent "$python_exe" "$env_file")"
        if [[ "$result" == "OK" ]]; then
            printf '%s\n' 'Consenso rilevato.'
            return 0
        fi
    done
    fail "consenso non rilevato. Fai accettare il link a un Global Administrator e rilancia lo script: $url"
}

# Verifica con le credenziali dell app l accesso alle API admin di Power Platform: stampa OK oppure nulla.
test_power_platform_access() {
    local python_exe="$1" env_file="$2" script output
    script="$(mktemp)"
    cat > "$script" <<'PY'
import sys
import urllib.request

env = {}
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
try:
    from azure.identity import ClientSecretCredential
    credential = ClientSecretCredential(env["TENANT_ID"], env["CLIENT_ID"], env["CLIENT_SECRET"])
    token = credential.get_token("https://api.bap.microsoft.com/.default").token
    url = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01"
    urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + token}), timeout=30)
    print("OK")
except Exception:
    pass
PY
    output="$("$python_exe" "$script" "$env_file" 2>/dev/null || true)"
    rm -f "$script"
    printf '%s' "$output"
}

# Le API admin di Power Platform rifiutano (403) un app non registrata come applicazione di gestione; l app non puo registrarsi da sola.
confirm_power_platform_access() {
    local python_exe="$1" env_file="$2" script answer="" registered poll
    local poll_seconds="${ARA_CONSENT_POLL_SECONDS:-10}"

    if [[ "$(test_power_platform_access "$python_exe" "$env_file")" == "OK" ]]; then
        printf '%s\n' 'Accesso alle API Power Platform verificato.'
        return 0
    fi

    printf '%s\n' 'L app non ha accesso alle API admin di Power Platform (403): va registrata come applicazione di gestione.'
    if ! { : < /dev/tty; } 2>/dev/null; then
        printf '%s\n' 'Avviso: registrazione saltata (input non interattivo): Power Platform e Copilot Studio risulteranno parziali.' >&2
        return 0
    fi
    printf '%s\n' 'Serve il login di un amministratore Power Platform con codice dispositivo (scade dopo 120 secondi).'
    read -r -p 'Premi Invio quando sei pronto (N per saltare) ' answer < /dev/tty
    [[ "$answer" =~ ^[nN] ]] && return 0

    script="$(mktemp --suffix=.ps1)"
    cat > "$script" <<'PS'
param([string]$TenantId, [string]$AppId)
$ErrorActionPreference = 'Stop'
try {
    Connect-AzAccount -Tenant $TenantId -UseDeviceAuthentication -WarningAction SilentlyContinue | Out-Null
    $token = (Get-AzAccessToken -ResourceUrl 'https://api.bap.microsoft.com' -WarningAction SilentlyContinue).Token
    if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
    $uri = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications/${AppId}?api-version=2020-10-01"
    Invoke-RestMethod -Method Put -Uri $uri -Headers @{ Authorization = "Bearer $token" } | Out-Null
    Write-Output 'Applicazione registrata in Power Platform.'
}
catch {
    Write-Output ('ERRORE: ' + $_.Exception.Message)
    exit 1
}
PS
    registered=true
    pwsh -NoProfile -File "$script" -TenantId "$(env_file_value "$env_file" TENANT_ID)" -AppId "$(env_file_value "$env_file" CLIENT_ID)" || registered=false
    rm -f "$script"
    if [[ "$registered" == false ]]; then
        printf '%s\n' 'Avviso: registrazione non riuscita: l account deve essere Power Platform Administrator. Si prosegue con dati parziali.' >&2
        return 0
    fi

    printf '%s\n' 'Attendo l attivazione della registrazione (fino a 2 minuti)...'
    for ((poll = 0; poll < 12; poll++)); do
        sleep "$poll_seconds"
        if [[ "$(test_power_platform_access "$python_exe" "$env_file")" == "OK" ]]; then
            printf '%s\n' 'Accesso alle API Power Platform verificato.'
            return 0
        fi
    done
    printf '%s\n' 'Avviso: la registrazione non risulta ancora attiva: si prosegue, Power Platform e Copilot Studio potrebbero risultare parziali.' >&2
}

if [[ "$check_only" == true ]]; then
    command -v git >/dev/null 2>&1 && git_present=true || git_present=false
    python_ok && python_present=true || python_present=false
    print_status 'git' "$git_present"
    print_status 'Python 3.8+ con venv' "$python_present"
    if ((${#module_names[@]} > 0)); then
        pwsh_ok && pwsh_present=true || pwsh_present=false
        print_status 'PowerShell 7 (pwsh)' "$pwsh_present"
    fi
    if [[ "$needs_gh" == true ]]; then
        command -v gh >/dev/null 2>&1 && gh_present=true || gh_present=false
        print_status 'GitHub CLI (gh)' "$gh_present"
    fi
    printf '%s\n' 'Controlli completati. Nessuna modifica eseguita: i componenti mancanti verranno installati senza --check-only.'
    exit 0
fi

# params.py della repository contiene un tenant di esempio: va sempre indicato quello del cliente.
if [[ "$run_after" == true && -z "$tenant_id" ]]; then
    { : < /dev/tty; } 2>/dev/null || fail 'tenant non indicato: usa --tenant-id.'
    read -r -p 'Tenant del cliente (GUID o dominio, es. contoso.onmicrosoft.com): ' tenant_id < /dev/tty
    [[ -n "$tenant_id" ]] || fail 'tenant non indicato: usa --tenant-id.'
fi

ensure_git_and_python

if ((${#module_names[@]} > 0)) && ! pwsh_ok; then
    install_pwsh
    pwsh_ok || fail 'PowerShell 7 (pwsh) non funzionante dopo l installazione.'
fi

# A365 richiede GitHub CLI.
if [[ "$needs_gh" == true ]] && ! command -v gh >/dev/null 2>&1; then
    install_gh
    command -v gh >/dev/null 2>&1 || fail 'GitHub CLI (gh) non disponibile dopo l installazione.'
fi

if [[ -d "$install_dir/.git" ]]; then
    printf 'Aggiorno la repository in %s...\n' "$install_dir"
    reset_upstream_fixes
    git -C "$install_dir" pull --ff-only || fail "aggiornamento non riuscito: verifica le modifiche locali in $install_dir."
else
    if [[ -d "$install_dir" ]] && [[ -n "$(ls -A "$install_dir")" ]]; then
        fail "la cartella $install_dir esiste e non e una repository git. Cancellala o scegli un altra --dir."
    fi
    printf 'Scarico la repository (branch %s) in %s...\n' "$branch" "$install_dir"
    git clone --depth 1 --branch "$branch" "$repo_url" "$install_dir" || fail "clone non riuscito da $repo_url."
fi

if [[ "$apply_patch" == true ]]; then
    apply_upstream_fixes
else
    printf '%s\n' 'Codice Microsoft originale, senza correzioni (per applicarle: --patch). Alcuni indicatori M365 possono risultare 0 anche se il tenant ha attivita.'
fi

requirements_file="$install_dir/requirements.txt"
[[ -f "$requirements_file" ]] || fail "requirements.txt non trovato in $install_dir."

venv_path="$install_dir/.venv"
if [[ ! -d "$venv_path" ]]; then
    printf 'Creo l ambiente Python in %s...\n' "$venv_path"
    python3 -m venv "$venv_path"
fi

venv_python="$venv_path/bin/python"
[[ -x "$venv_python" ]] || fail "interprete Python dell ambiente virtuale non trovato: $venv_python"

printf '%s\n' 'Aggiorno pip e installo le dipendenze Python...'
"$venv_python" -m pip install --quiet --upgrade pip
"$venv_python" -m pip install --quiet -r "$requirements_file"

for index in ${module_names[@]+"${!module_names[@]}"}; do
    module_name="${module_names[$index]}"
    module_check="${module_checks[$index]}"

    if pwsh -NoProfile -Command "if (Get-Module -ListAvailable -Name '$module_check') { exit 0 } else { exit 1 }"; then
        printf 'Modulo PowerShell presente: %s\n' "$module_name"
        continue
    fi

    printf 'Installo il modulo PowerShell %s...\n' "$module_name"
    pwsh -NoProfile -Command "Install-Module -Name '$module_name' -Scope CurrentUser -Force -AllowClobber" || true
    # Install-Module puo terminare con un avviso senza installare nulla: si verifica il risultato.
    pwsh -NoProfile -Command "if (Get-Module -ListAvailable -Name '$module_check') { exit 0 } else { exit 1 }" \
        || fail "installazione del modulo $module_name non riuscita."
done

printf '%s\n' 'Installazione completata.'
printf 'Cartella del progetto: %s\n' "$install_dir"

declare -a main_args=()
if [[ -n "$tenant_id" ]]; then
    main_args+=(--tenant-id "$tenant_id")
fi
if [[ "$analyze_all" == false ]]; then
    main_args+=(--services "${analyze_services[@]}")
fi

if [[ "$run_after" == true || "$check_consent" == true ]]; then
    # La versione upstream di main.py non avvia da sola il setup: lo fa lo script se mancano le credenziali.
    env_file="$install_dir/.env"
    if [[ "$run_after" == true && ! -f "$env_file" && -z "${CLIENT_ID:-}" ]]; then
        printf '%s\n' 'Credenziali non presenti: avvio il login con l account amministratore del tenant del cliente (Global Administrator).'
        printf '%s\n' 'Il login usa un codice dispositivo che scade dopo 120 secondi: apri prima https://login.microsoft.com/device con l account amministratore.'
        if { : < /dev/tty; } 2>/dev/null; then
            read -r -p 'Premi Invio quando sei pronto ' _ < /dev/tty
        fi
        (cd "$install_dir" && pwsh -NoProfile -File ./setup-service-principal.ps1)
        [[ -f "$env_file" ]] || fail "setup delle credenziali non completato: il file .env non e stato creato."
    fi

    if [[ -f "$env_file" ]]; then
        confirm_admin_consent "$venv_python" "$env_file"
        if [[ "$run_after" == true && "$needs_pp" == true ]]; then
            confirm_power_platform_access "$venv_python" "$env_file"
        fi
    elif [[ "$check_consent" == true ]]; then
        fail "file .env non trovato in $install_dir: esegui prima il setup delle credenziali."
    fi
fi

if [[ "$run_after" == true ]]; then
    printf '%s\n' 'Avvio l assessment...'
    cd "$install_dir"
    exec "$venv_python" main.py ${main_args[@]+"${main_args[@]}"}
fi

if [[ "$check_consent" == true ]]; then
    exit 0
fi

if ((${#module_names[@]} > 0)); then
    printf '%s\n' 'Se pwsh non e nel PATH, aggiungi: export PATH="$HOME/.local/bin:$PATH"'
fi
printf '%s\n' 'Per avviare l assessment (con login al primo avvio):'
declare -a hint_args=(${main_args[@]+"${main_args[@]}"})
if [[ -z "$tenant_id" ]]; then
    hint_args=(--tenant-id '<TENANT-DEL-CLIENTE>' ${hint_args[@]+"${hint_args[@]}"})
fi
printf '  cd "%s" && "%s" main.py %s\n' "$install_dir" "$venv_python" "${hint_args[*]}"
