# Standalone: non servono altri file. Controlla (e se manca installa) Git, Python e,
# se servono moduli PowerShell, PowerShell 7; poi clona la repository ARA e prepara l'ambiente.
# Funziona da Windows PowerShell 5.1 e da PowerShell 7.
#
# Giro completo (tutti i servizi, con login e assessment), con il tenant del cliente in una variabile:
#   $TenantId = "<TENANT-DEL-CLIENTE>"   # GUID o dominio, es. contoso.onmicrosoft.com
#   pwsh -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows.ps1 -Services All -TenantId $TenantId -Run
#
# Stesso giro da URL, senza avere il file in locale:
#   $TenantId = "<TENANT-DEL-CLIENTE>"
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/alessandrorapitiagic/m365agent-readiness-assessment/main/scripts/bootstrap_windows.ps1))) -Services All -TenantId $TenantId -Run
#
# Solo alcuni servizi, senza avviare l'assessment:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/alessandrorapitiagic/m365agent-readiness-assessment/main/scripts/bootstrap_windows.ps1))) -Services "Purview","A365"
#
# Di default il codice Microsoft resta quello originale. Con -Patch si applicano le correzioni descritte nel README.
[CmdletBinding()]
param(
    [ValidateSet("M365", "Entra", "Defender", "Power Platform", "Copilot Studio", "Purview", "A365", "All")]
    [string[]]$Services = @(),
    [switch]$IncludeSetupModule,
    [switch]$CheckOnly,
    # Dopo l'installazione avvia python main.py: se manca il file .env parte il login e la creazione dell'app registration.
    [switch]$Run,
    # Verifica solo il consenso amministrativo dell'app (dopo aver preparato l'ambiente) e termina.
    [switch]$CheckConsent,
    [string]$TenantId,
    # Applica le correzioni al codice Microsoft (vedi il blocco $upstreamFixPatch piu' sotto). Senza -Patch il codice resta originale.
    [switch]$Patch,
    [string]$VenvPath,
    [string]$InstallPath = (Join-Path $env:USERPROFILE "m365-ara"),
    [string]$Branch = "main",
    [string]$RepositoryUrl = "https://github.com/microsoft/m365-copilot-automated-readiness-assessment.git"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Install-WingetPackage {
    param([string]$Id, [string]$Name)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return
    }
    Write-Host "Installo $Name con winget (potrebbe comparire la richiesta di conferma di Windows)..."
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Host
    Update-SessionPath
}

function Install-Git {
    Install-WingetPackage -Id "Git.Git" -Name "Git"
    if (Get-Command git -ErrorAction SilentlyContinue) { return }

    Write-Host "Scarico il client Git for Windows da GitHub..."
    $suffix = "64-bit"
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $suffix = "arm64" }
    elseif (-not [Environment]::Is64BitOperatingSystem) { $suffix = "32-bit" }

    # Il redirect di /releases/latest evita le API GitHub, soggette a rate limit senza autenticazione.
    $latest = Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/latest" -UseBasicParsing
    if ($latest.BaseResponse.PSObject.Properties.Name -contains "RequestMessage") {
        $latestUrl = $latest.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    }
    else {
        $latestUrl = $latest.BaseResponse.ResponseUri.AbsoluteUri
    }
    if ($latestUrl -notmatch "/tag/(v(\d+\.\d+\.\d+)\.windows\.(\d+))$") {
        throw "Versione di Git non riconosciuta ($latestUrl). Installa Git manualmente da https://git-scm.com/download/win e rilancia lo script."
    }
    $tag = $Matches[1]
    $version = $Matches[2]
    if ($Matches[3] -ne "1") { $version = "$version.$($Matches[3])" }

    $assetName = "Git-$version-$suffix.exe"
    $assetUrl = "https://github.com/git-for-windows/git/releases/download/$tag/$assetName"

    $installer = Join-Path ([System.IO.Path]::GetTempPath()) $assetName
    try {
        Invoke-WebRequest -Uri $assetUrl -OutFile $installer -UseBasicParsing
        $signature = Get-AuthenticodeSignature -FilePath $installer
        if ($signature.Status -ne "Valid") {
            throw "La firma dell'installer di Git non e' valida ($($signature.Status)). Installazione annullata."
        }
        $process = Start-Process -FilePath $installer -ArgumentList "/VERYSILENT", "/NORESTART" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installazione di Git non riuscita (codice $($process.ExitCode))."
        }
    }
    finally {
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
    }

    Update-SessionPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitCmd = Join-Path $env:ProgramFiles "Git\cmd"
        if (Test-Path (Join-Path $gitCmd "git.exe")) { $env:Path = "$env:Path;$gitCmd" }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git risulta installato ma non e' raggiungibile. Riapri PowerShell e rilancia lo script."
    }
}

function Get-LatestPythonWingetId {
    $fallback = "Python.Python.3.13"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $fallback }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $output = & winget search --id Python.Python. --source winget --accept-source-agreements 2>$null | Out-String }
    catch { $output = "" }
    $ErrorActionPreference = $previousPreference

    $latest = 0
    foreach ($match in [regex]::Matches($output, 'Python\.Python\.3\.(\d+)\b')) {
        $minor = [int]$match.Groups[1].Value
        if ($minor -gt $latest) { $latest = $minor }
    }
    if ($latest -lt 8) { return $fallback }
    return "Python.Python.3.$latest"
}

function Get-PythonCommand {
    $candidates = @(
        @{ Name = "py"; Prefix = @("-3") },
        @{ Name = "python"; Prefix = @() }
    )
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate.Name -ErrorAction SilentlyContinue
        if (-not $command) { continue }

        $checkArgs = @($candidate.Prefix) + @("-c", "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)")
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 1
        try { & $command.Source @checkArgs *> $null } catch { $global:LASTEXITCODE = 1 }
        $ErrorActionPreference = $previousPreference

        if ($LASTEXITCODE -eq 0) {
            return @{ Path = $command.Source; Prefix = $candidate.Prefix }
        }
    }
    return $null
}

function Write-Status {
    param([string]$Name, [bool]$Present)

    if ($Present) { Write-Host ("[OK]       {0}" -f $Name) }
    else { Write-Host ("[MANCANTE] {0}" -f $Name) }
}

$requiredConsentRoles = @("Reports.Read.All", "User.Read.All", "Sites.Read.All", "Policy.Read.All", "AuditLog.Read.All", "Directory.Read.All")

$consentCheckScript = @'
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
'@

function Get-EnvFileValue {
    param([string]$File, [string]$Name)

    $match = Select-String -Path $File -Pattern "^$Name=(.+)$" | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.Matches[0].Groups[1].Value.Trim().Trim('"')
}

function Test-AppConsent {
    param([string]$PythonExe, [string]$EnvFile)

    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ara-consent-" + [guid]::NewGuid().ToString("N") + ".py")
    try {
        Set-Content -Path $scriptFile -Value $consentCheckScript -Encoding UTF8
        $text = (& $PythonExe $scriptFile $EnvFile ($requiredConsentRoles -join ",") | Out-String).Trim()
    }
    finally {
        Remove-Item -Path $scriptFile -Force -ErrorAction SilentlyContinue
    }

    $line = @($text -split "\r?\n" | Where-Object { $_ -match '^(OK$|MISSING:|ERROR:)' }) | Select-Object -Last 1
    if ($line -eq "OK") { return @{ Status = "OK"; Detail = "" } }
    if ($line -like "MISSING:*") { return @{ Status = "MISSING"; Detail = $line.Substring(8) } }
    if ($line -like "ERROR:*") { return @{ Status = "ERROR"; Detail = $line.Substring(6) } }
    return @{ Status = "ERROR"; Detail = "risposta inattesa dal controllo" }
}

function Confirm-AdminConsent {
    param([string]$PythonExe, [string]$EnvFile)

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $result = Test-AppConsent -PythonExe $PythonExe -EnvFile $EnvFile
        if ($result.Status -ne "ERROR") { break }
        if ($attempt -lt 4) { Start-Sleep -Seconds 10 }
    }
    if ($result.Status -eq "ERROR") {
        throw "Impossibile verificare il consenso dell'app: $($result.Detail)"
    }
    if ($result.Status -eq "OK") {
        Write-Host "Consenso amministrativo verificato: i permessi dell'app sono concessi."
        return
    }

    $tenant = Get-EnvFileValue -File $EnvFile -Name "TENANT_ID"
    $client = Get-EnvFileValue -File $EnvFile -Name "CLIENT_ID"
    $url = "https://login.microsoftonline.com/$tenant/adminconsent?client_id=$client"
    Write-Host "Mancano permessi concessi all'app: $($result.Detail)"
    Write-Host "Un Global Administrator del tenant deve accettare qui: $url"
    try { Start-Process $url } catch { Write-Host "Apri il link nel browser." }
    Write-Host "Attendo il consenso (fino a 5 minuti)..."
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 10
        $result = Test-AppConsent -PythonExe $PythonExe -EnvFile $EnvFile
        if ($result.Status -eq "OK") {
            Write-Host "Consenso rilevato."
            return
        }
    }
    throw "Consenso non rilevato. Fai accettare il link a un Global Administrator e rilancia lo script: $url"
}

# Le API admin di Power Platform rifiutano (403) un'app non registrata come applicazione di gestione; l'app non puo' registrarsi da sola.
$powerPlatformRegisterScript = @'
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
'@

function Test-PowerPlatformAccess {
    param([string]$EnvFile)

    $tenant = Get-EnvFileValue -File $EnvFile -Name "TENANT_ID"
    $client = Get-EnvFileValue -File $EnvFile -Name "CLIENT_ID"
    $secret = Get-EnvFileValue -File $EnvFile -Name "CLIENT_SECRET"
    try {
        $token = Invoke-RestMethod -Method Post -UseBasicParsing -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{
            grant_type = "client_credentials"; client_id = $client; client_secret = $secret; scope = "https://api.bap.microsoft.com/.default"
        }
        Invoke-RestMethod -UseBasicParsing -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01" `
            -Headers @{ Authorization = "Bearer $($token.access_token)" } | Out-Null
        return $true
    }
    catch { return $false }
}

function Confirm-PowerPlatformAccess {
    param([string]$EnvFile)

    if (Test-PowerPlatformAccess -EnvFile $EnvFile) {
        Write-Host "Accesso alle API Power Platform verificato."
        return
    }

    Write-Host "L'app non ha accesso alle API admin di Power Platform (403): va registrata come applicazione di gestione."
    if ([Console]::IsInputRedirected) {
        Write-Warning "Registrazione saltata (input non interattivo): Power Platform e Copilot Studio risulteranno parziali."
        return
    }
    Write-Host "Serve il login di un amministratore Power Platform con codice dispositivo (scade dopo 120 secondi)."
    $answer = Read-Host "Premi Invio quando sei pronto (N per saltare)"
    if ($answer -match '^[nN]') { return }

    $tenant = Get-EnvFileValue -File $EnvFile -Name "TENANT_ID"
    $client = Get-EnvFileValue -File $EnvFile -Name "CLIENT_ID"
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ara-pp-register-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Set-Content -Path $scriptFile -Value $powerPlatformRegisterScript -Encoding UTF8
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptFile -TenantId $tenant -AppId $client
        $registered = $LASTEXITCODE -eq 0
    }
    finally {
        Remove-Item -Path $scriptFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $registered) {
        Write-Warning "Registrazione non riuscita: l'account deve essere Power Platform Administrator. Si prosegue con dati parziali."
        return
    }

    Write-Host "Attendo l'attivazione della registrazione (fino a 2 minuti)..."
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 10
        if (Test-PowerPlatformAccess -EnvFile $EnvFile) {
            Write-Host "Accesso alle API Power Platform verificato."
            return
        }
    }
    Write-Warning "La registrazione non risulta ancora attiva: si prosegue, Power Platform e Copilot Studio potrebbero risultare parziali."
}

# M365, Entra e Defender usano solo Python: non richiedono moduli PowerShell.
$analyzeAllServices = $Services.Count -eq 0 -or $Services -contains "All"
$analyzeServices = @($Services | Where-Object { $_ -ne "All" })
if ($Run) {
    # Il login iniziale usa Microsoft.Graph; senza -Services si analizza tutto, quindi servono tutti i moduli.
    $IncludeSetupModule = $true
    if ($Services.Count -eq 0) { $Services = @("All") }
}
$allServices = $Services -contains "All"
$needsGitHubCli = $allServices -or $Services -contains "A365"
$needsPowerPlatform = $allServices -or $Services -contains "Power Platform" -or $Services -contains "Copilot Studio"

# params.py della repository contiene un tenant di esempio: va sempre indicato quello del cliente.
if ($Run -and -not $CheckOnly -and [string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = Read-Host "Tenant del cliente (GUID o dominio, es. contoso.onmicrosoft.com)"
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "Tenant non indicato: rilancia lo script con -TenantId."
    }
}
$modules = @()
if ($allServices -or $Services -contains "Power Platform" -or $Services -contains "Copilot Studio") {
    $modules += @{ Name = "Az"; Check = "Az.Accounts" }
}
if ($allServices -or $Services -contains "Purview") {
    $modules += @{ Name = "ExchangeOnlineManagement"; Check = "ExchangeOnlineManagement" }
}
if ($allServices -or $Services -contains "A365" -or $IncludeSetupModule) {
    $modules += @{ Name = "Microsoft.Graph"; Check = "Microsoft.Graph.Authentication" }
}

$longPathsEnabled = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($longPathsEnabled -ne 1) {
    throw "Windows Long Paths risulta disattivato. Da PowerShell come amministratore, esegui: Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1. Poi riavvia Windows e rilancia lo script."
}

$installPath = [System.IO.Path]::GetFullPath($InstallPath)
if ([string]::IsNullOrWhiteSpace($VenvPath)) {
    $VenvPath = Join-Path $env:USERPROFILE ".m365-ara-venv"
}
$venvPath = [System.IO.Path]::GetFullPath($VenvPath)

if ($CheckOnly) {
    Write-Status "Git" ([bool](Get-Command git -ErrorAction SilentlyContinue))
    Write-Status "Python 3.8 o successivo" ($null -ne (Get-PythonCommand))
    if ($modules.Count -gt 0) {
        Write-Status "PowerShell 7 (pwsh)" ([bool](Get-Command pwsh -ErrorAction SilentlyContinue))
    }
    if ($needsGitHubCli) {
        Write-Status "GitHub CLI (gh)" ([bool](Get-Command gh -ErrorAction SilentlyContinue))
    }
    Write-Host "Controlli completati. Nessuna modifica eseguita: i componenti mancanti verranno installati senza -CheckOnly."
    return
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Install-Git
}

$python = Get-PythonCommand
if (-not $python) {
    $pythonId = Get-LatestPythonWingetId
    Install-WingetPackage -Id $pythonId -Name "Python ($pythonId)"
    $python = Get-PythonCommand
}
if (-not $python) {
    throw "Python 3.8 o successivo non disponibile. Installalo da https://www.python.org/downloads/ (con Add python.exe to PATH), riapri PowerShell e rilancia lo script."
}

if ($modules.Count -gt 0 -and -not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Install-WingetPackage -Id "Microsoft.PowerShell" -Name "PowerShell 7"
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        throw "PowerShell 7 (pwsh) non disponibile. Installalo da https://aka.ms/powershell, riapri PowerShell e rilancia lo script."
    }
}

# A365 richiede GitHub CLI: installandola qui il PATH e' gia' aggiornato quando parte l'assessment.
if ($needsGitHubCli -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Install-WingetPackage -Id "GitHub.cli" -Name "GitHub CLI"
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "GitHub CLI (gh) non disponibile: installala da https://cli.github.com/ e rilancia lo script, altrimenti A365 si ferma."
    }
}

# Il codice si scarica solo dalla repository pubblica Microsoft. Con -Patch si applica una piccola patch
# (6 file) che corregge difetti: il codice Microsoft legge il report degli utenti attivi con
# le colonne di un altro report e usa chiavi mai definite, quindi molti indicatori M365 risultano 0 anche se il
# tenant ha attivita'; 4 raccomandazioni chiamano metodi Graph inesistenti; lo script di setup apre il login nel
# browser, che fallisce su server o sessioni remote, e passa al codice dispositivo. La patch si applica solo se il
# codice scaricato e' quello atteso, altrimenti viene saltata con un avviso.
$upstreamFixPatch = @'
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
'@

function Get-UpstreamFixFiles {
    foreach ($match in [regex]::Matches($upstreamFixPatch, '(?m)^diff --git a/(\S+) ')) { $match.Groups[1].Value }
}

# Riporta i file della patch allo stato originale, cosi' il pull non trova modifiche locali.
function Reset-UpstreamFixes {
    param([string]$RepoPath)
    $ErrorActionPreference = "Continue"
    foreach ($file in Get-UpstreamFixFiles) {
        & git -C $RepoPath checkout -- $file 2>$null
    }
}

function Install-UpstreamFixes {
    param([string]$RepoPath)
    $ErrorActionPreference = "Continue"
    $files = @(Get-UpstreamFixFiles)
    $patchFile = Join-Path ([IO.Path]::GetTempPath()) ("ara-fix-{0}.patch" -f [guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllText($patchFile, (($upstreamFixPatch -replace "`r`n", "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        & git -C $RepoPath apply --check --ignore-whitespace $patchFile 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Applico $($files.Count) correzioni al codice Microsoft. Perche':"
            Write-Host "  - legge il report degli utenti attivi con le colonne di un altro report e usa chiavi mai definite: molti indicatori M365 risultano 0 (es. '0 active users') anche se il tenant ha attivita'."
            Write-Host "  - 4 raccomandazioni (Teams, Exchange, Power Virtual Agents) chiamano metodi Graph inesistenti e non producono dati."
            Write-Host "  - lo script di setup apre il login nel browser: su server o sessioni remote fallisce (Authentication failed or was cancelled). Si usa il codice dispositivo."
            Write-Host "  Si modificano solo questi file: $($files -join ', ')."
            & git -C $RepoPath apply --ignore-whitespace $patchFile
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Applicazione delle correzioni non riuscita: il report puo' contenere indicatori a 0 non reali."
            }
            return
        }
        & git -C $RepoPath apply --reverse --check --ignore-whitespace $patchFile 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Correzioni al codice Microsoft gia' presenti."
            return
        }
        Write-Warning "Il codice Microsoft e' cambiato rispetto a quello atteso: correzioni NON applicate. Il report puo' contenere indicatori a 0 non reali."
    }
    finally {
        Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path (Join-Path $installPath ".git")) {
    Write-Host "Aggiorno la repository in $installPath..."
    Reset-UpstreamFixes -RepoPath $installPath
    & git -C $installPath pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        throw "Aggiornamento della repository non riuscito. Verifica eventuali modifiche locali in $installPath."
    }
}
else {
    if ((Test-Path $installPath) -and (Get-ChildItem -Path $installPath -Force | Select-Object -First 1)) {
        throw "La cartella $installPath esiste e non e' una repository git. Cancellala o scegli un altro -InstallPath."
    }
    Write-Host "Scarico la repository (branch $Branch) in $installPath..."
    & git -c core.longpaths=true clone --depth 1 --branch $Branch $RepositoryUrl $installPath
    if ($LASTEXITCODE -ne 0) {
        throw "Clone della repository non riuscito da $RepositoryUrl. Verifica la connessione e il nome del branch."
    }
}
& git -C $installPath config core.longpaths true

if ($Patch) {
    Install-UpstreamFixes -RepoPath $installPath
}
else {
    Write-Host "Codice Microsoft originale, senza correzioni (per applicarle: -Patch). Alcuni indicatori M365 possono risultare 0 anche se il tenant ha attivita'."
}
$requirementsFile = Join-Path $installPath "requirements.txt"
if (-not (Test-Path $requirementsFile)) {
    throw "File requirements.txt non trovato in $installPath."
}

if (-not (Test-Path $venvPath)) {
    Write-Host "Creo l'ambiente Python in $venvPath..."
    $venvArgs = @($python.Prefix) + @("-m", "venv", $venvPath)
    & $python.Path @venvArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Creazione dell'ambiente virtuale non riuscita. Verifica che il modulo venv sia disponibile."
    }
}

$venvPython = Join-Path $venvPath "Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    throw "Interprete Python dell'ambiente virtuale non trovato: $venvPython"
}

Write-Host "Aggiorno pip e installo le dipendenze Python..."
& $venvPython -m pip install --quiet --disable-pip-version-check --upgrade pip
if ($LASTEXITCODE -ne 0) {
    throw "Aggiornamento di pip non riuscito."
}
& $venvPython -m pip install --quiet --disable-pip-version-check -r $requirementsFile
if ($LASTEXITCODE -ne 0) {
    throw "Installazione delle dipendenze Python non riuscita."
}

foreach ($module in $modules) {
    & pwsh -NoProfile -Command "if (Get-Module -ListAvailable -Name '$($module.Check)') { exit 0 } else { exit 1 }"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Modulo PowerShell presente: $($module.Name)"
        continue
    }

    Write-Host "Installo il modulo PowerShell $($module.Name)..."
    & pwsh -NoProfile -Command "Install-Module -Name '$($module.Name)' -Scope CurrentUser -Force -AllowClobber"
    # Install-Module puo' terminare con un avviso senza installare nulla: si verifica il risultato.
    & pwsh -NoProfile -Command "if (Get-Module -ListAvailable -Name '$($module.Check)') { exit 0 } else { exit 1 }"
    if ($LASTEXITCODE -ne 0) {
        throw "Installazione del modulo $($module.Name) non riuscita. Chiudi le altre finestre PowerShell e rilancia lo script."
    }
}

Write-Host "Installazione completata."
Write-Host "Cartella del progetto: $installPath"

$mainArgs = @()
if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $mainArgs += @("--tenant-id", $TenantId) }
if (-not $analyzeAllServices) { $mainArgs += @("--services") + $analyzeServices }

if ($Run -or $CheckConsent) {
    # La versione upstream di main.py non avvia da sola il setup: lo fa lo script se mancano le credenziali.
    $envFile = Join-Path $installPath ".env"
    if ($Run -and -not (Test-Path $envFile) -and -not $env:CLIENT_ID) {
        $setupScript = Join-Path $installPath "setup-service-principal.ps1"
        Write-Host "Credenziali non presenti: avvio il login con l'account amministratore del tenant del cliente (Global Administrator)."
        Write-Host "Lo script crea l'app registration e salva le credenziali in $envFile."
        Write-Host "Il login usa un codice dispositivo che scade dopo 120 secondi: apri prima https://login.microsoft.com/device con l'account amministratore."
        if (-not [Console]::IsInputRedirected) { [void](Read-Host "Premi Invio quando sei pronto") }
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $setupScript
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $envFile)) {
            throw "Setup delle credenziali non completato: il file .env non e' stato creato."
        }
    }

    if (Test-Path $envFile) {
        Confirm-AdminConsent -PythonExe $venvPython -EnvFile $envFile
        if ($Run -and $needsPowerPlatform) { Confirm-PowerPlatformAccess -EnvFile $envFile }
    }
    elseif ($CheckConsent) {
        throw "File .env non trovato in ${installPath}: esegui prima il setup delle credenziali."
    }
}

if ($Run) {
    Write-Host "Avvio l'assessment..."
    Push-Location $installPath
    try {
        & $venvPython main.py @mainArgs
        if ($LASTEXITCODE -ne 0) {
            throw "L'assessment e' terminato con errore (codice $LASTEXITCODE)."
        }
    }
    finally {
        Pop-Location
    }
    return
}

if ($CheckConsent) { return }

Write-Host "Per avviare l'assessment (con login al primo avvio):"
Write-Host ('  Set-Location "{0}"' -f $installPath)
if ([string]::IsNullOrWhiteSpace($TenantId)) { $mainArgs = @("--tenant-id", "<TENANT-DEL-CLIENTE>") + $mainArgs }
Write-Host ('  & "{0}" main.py {1}' -f $venvPython, ($mainArgs -join " "))
