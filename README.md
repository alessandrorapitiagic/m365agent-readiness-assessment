# m365agent-readiness-assessment

Strumenti per eseguire in modo ripetibile, su Windows, Linux o in un container Docker, il
[M365 Copilot Automated Readiness Assessment](https://github.com/microsoft/m365-copilot-automated-readiness-assessment) di Microsoft.

Questa repository **non contiene codice Microsoft**. Gli script scaricano la repository pubblica Microsoft,
preparano l'ambiente e lanciano l'assessment. L'assessment, le raccomandazioni e le istruzioni di esecuzione
restano quelli di Microsoft:

- Repository Microsoft: <https://github.com/microsoft/m365-copilot-automated-readiness-assessment>
- Istruzioni di esecuzione Microsoft: [RUN.md](https://github.com/microsoft/m365-copilot-automated-readiness-assessment/blob/main/RUN.md)
- Prerequisiti Microsoft: [prereq.md](https://github.com/microsoft/m365-copilot-automated-readiness-assessment/blob/main/prereq.md)

## Contenuto

| Percorso | Funzione |
| --- | --- |
| [scripts/bootstrap_windows.ps1](scripts/bootstrap_windows.ps1) | Bootstrap per Windows (PowerShell 5.1 e 7) |
| [scripts/bootstrap_linux.sh](scripts/bootstrap_linux.sh) | Bootstrap per Linux (apt, dnf, yum) |
| [sandbox/](sandbox) | Container Docker pulito con procedura guidata. Guida: [docs/SANDBOX-GUIDE-STE100.md](docs/SANDBOX-GUIDE-STE100.md) |
| [tests/docker/](tests/docker) | Test automatici del bootstrap Linux su una macchina pulita |

## Cosa fa il bootstrap

Ogni script e' autonomo: non servono altri file.

1. Controlla e, se mancano, installa Git e Python 3.8 o successivo. Su Windows installa l'ultimo Python con winget.
2. Se i servizi scelti lo richiedono, installa PowerShell 7 e i moduli PowerShell (`Az`, `ExchangeOnlineManagement`, `Microsoft.Graph`).
3. Se il servizio A365 e' scelto, installa GitHub CLI (`gh`): l'assessment Microsoft la richiede per A365.
4. Clona la repository pubblica Microsoft in `~/m365-ara` (Windows: `%USERPROFILE%\m365-ara`) e crea l'ambiente Python.
5. Con `-Run` / `--run`:
   - se manca il file `.env`, lancia `setup-service-principal.ps1` di Microsoft: crea l'app registration e salva le credenziali (serve un Global Administrator);
   - verifica che il consenso amministrativo sia concesso e, se manca, mostra il link e attende fino a 5 minuti;
   - se sono scelti Power Platform o Copilot Studio, verifica l'accesso alle API admin e, se riceve 403, registra l'app come applicazione di gestione Power Platform (serve un Power Platform Administrator);
   - avvia `main.py` con tenant e servizi scelti.

### Windows

```powershell
$TenantId = "<TENANT-DEL-CLIENTE>"   # GUID o dominio, es. contoso.onmicrosoft.com
pwsh -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows.ps1 -Services All -TenantId $TenantId -Run
```

Senza avere il file in locale:

```powershell
$TenantId = "<TENANT-DEL-CLIENTE>"
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/alessandrorapitiagic/m365agent-readiness-assessment/main/scripts/bootstrap_windows.ps1))) -Services All -TenantId $TenantId -Run
```

Su Windows serve l'opzione Long Paths attiva: lo script la verifica e indica il comando se manca.

| Parametro | Funzione |
| --- | --- |
| `-Services` | `M365`, `Entra`, `Defender`, `"Power Platform"`, `"Copilot Studio"`, `Purview`, `A365`, `All` (anche piu' valori) |
| `-TenantId` | Tenant del cliente. Obbligatorio con `-Run` |
| `-Run` | Dopo l'installazione esegue setup credenziali, controllo del consenso e assessment |
| `-Patch` | Applica le correzioni al codice Microsoft (vedi [Patch](#patch-opzionale)) |
| `-ExperimentalLogin` | Prova il login a codice dispositivo per Purview (vedi [Login sperimentale](#login-sperimentale-purview)) |
| `-CheckOnly` | Mostra cosa manca senza modificare nulla |
| `-CheckConsent` | Verifica solo il consenso amministrativo dell'app |
| `-IncludeSetupModule` | Installa `Microsoft.Graph`, usato dal setup delle credenziali |
| `-InstallPath`, `-VenvPath`, `-Branch`, `-RepositoryUrl` | Percorsi, branch e repository da clonare |

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/alessandrorapitiagic/m365agent-readiness-assessment/main/scripts/bootstrap_linux.sh \
  | bash -s -- --run --tenant-id "<TENANT-DEL-CLIENTE>" --services all
```

| Opzione | Funzione |
| --- | --- |
| `--services` | `m365,entra,defender,power-platform,copilot-studio,purview,a365,all` (separati da virgola) |
| `--tenant-id` | Tenant del cliente. Obbligatorio con `--run` |
| `--run` | Dopo l'installazione esegue setup credenziali, controllo del consenso e assessment |
| `--patch` | Applica le correzioni al codice Microsoft (vedi [Patch](#patch-opzionale)) |
| `--experimental-login` | Prova il login a codice dispositivo per Purview (vedi [Login sperimentale](#login-sperimentale-purview)) |
| `--check-only` | Mostra cosa manca senza modificare nulla |
| `--check-consent` | Verifica solo il consenso amministrativo dell'app |
| `--include-setup-module` | Installa `Microsoft.Graph`, usato dal setup delle credenziali |
| `--dir`, `--branch`, `--repo-url` | Cartella, branch e repository da clonare |

## Patch (opzionale)

**Di default gli script non modificano il codice Microsoft.** Il codice resta quello originale clonato.

Con `-Patch` (Windows) o `--patch` (Linux) lo script applica una patch di 6 file, con `git apply`, e stampa il motivo di ogni correzione:

| Correzione | File | Perche' |
| --- | --- | --- |
| Utenti attivi M365 | `Core/get_m365_client.py` | Il codice legge il report degli utenti attivi con le colonne di un altro report e usa chiavi mai definite: molti indicatori risultano `0` anche se il tenant ha attivita'. La patch calcola i valori dalle colonne `Last Activity Date` per utente. |
| Raccomandazioni con metodi inesistenti | `Recommendations/m365/TEAMS1.py`, `Recommendations/m365/EXCHANGE_S_ENTERPRISE.py`, `Recommendations/copilot_studio/POWER_VIRTUAL_AGENTS_O365_P3.py`, `Recommendations/copilot_studio/VIRTUAL_AGENT_BASE_MESSAGES.py` | Chiamano metodi Graph che non esistono e non producono dati. La patch usa i report con periodo e legge il CSV. |
| Login con codice dispositivo | `setup-service-principal.ps1` | Lo script apre il login nel browser: su server, sessioni remote e container fallisce. La patch usa `-UseDeviceAuthentication`. |

Regole di funzionamento:

- La patch si applica solo se il codice Microsoft e' quello atteso. Se Microsoft cambia quei file, lo script mostra un avviso e non applica nulla.
- Ogni esecuzione riporta prima i file della patch allo stato originale. Rilanciare lo script **senza** `-Patch` / `--patch` riporta quindi il codice Microsoft originale.
- Se la patch e' gia' presente, lo script lo segnala e non la riapplica.
- Senza la patch, il login del setup usa il browser: nel container Docker serve la patch (la procedura guidata la propone di default).

La patch non e' una modifica approvata da Microsoft. Per usare solo il codice originale non usare l'opzione.

## Login sperimentale (Purview)

Il codice Microsoft usa login diversi a seconda del servizio: Graph, Azure e A365 hanno il codice dispositivo, il setup delle credenziali e Purview solo il browser. Il setup e' coperto da `--patch`. Per Purview c'e' una **seconda patch, separata**: `-ExperimentalLogin` (Windows) o `--experimental-login` (Linux). **Sperimentale: non e' verificata su tutti i tenant.**

| Parte | Cosa cambia | Stato |
| --- | --- | --- |
| Exchange Online | `Connect-ExchangeOnline -Device` | Opzione documentata da Microsoft; richiede PowerShell 7 |
| Security & Compliance (DLP, etichette) | `Connect-IPPSSession` non ha `-Device`: la patch ottiene un token con il codice dispositivo e lo passa con `-AccessToken` | Da verificare: richiede ExchangeOnlineManagement 3.8 o successivo e che il tenant accetti il flusso |
| Messaggio del codice | `Core/orchestrator_powershell.py` leggeva l'output solo a fine esecuzione: la patch mostra subito il codice | Necessario, altrimenti il codice non si vede |

Si applica ai file `collect_purview_data.ps1` e `Core/orchestrator_powershell.py`. Funziona indipendentemente da `--patch` e come quella viene tolta rilanciando senza l'opzione. Se non funziona, rilancia senza l'opzione e Purview torna al login nel browser.

## Sandbox Docker

La sandbox e' un container Ubuntu pulito con gli strumenti gia' installati e una procedura guidata
che chiede tenant e servizi. Utile quando non si vuole installare nulla sul PC.

```powershell
.\sandbox\start.ps1          # procedura guidata
.\sandbox\start.ps1 -Shell   # shell nel container
```

I report finiscono in `sandbox/reports` sul PC. Le credenziali restano in un volume Docker.
Guida passo passo: [docs/SANDBOX-GUIDE-STE100.md](docs/SANDBOX-GUIDE-STE100.md).

Limite: Purview usa di default un login nel browser che non e' disponibile nel container. La procedura guidata lo salta di default; se lo selezioni propone il [login sperimentale](#login-sperimentale-purview).

## Test

Il test crea un container pulito (senza Git, Python, PowerShell), clona la repository Microsoft (serve la rete)
ed esegue il bootstrap Linux in tutti gli scenari: installazione, aggiornamento, `--patch` e ripristino,
`--experimental-login` (da solo e insieme a `--patch`), `--check-only`, controllo del consenso, validazione dei parametri.

```powershell
.\tests\docker\run-bootstrap-test.ps1                # completo
.\tests\docker\run-bootstrap-test.ps1 -SkipModules   # salta l'installazione reale di PowerShell e dei moduli
```

## Note di sicurezza

- Il file `.env` contiene il segreto dell'app. Non condividerlo e non committarlo. Il segreto scade dopo 30 giorni.
- Al termine dell'assessment elimina l'app registration dal tenant del cliente.
- Il CSV dei report contiene nomi di persone e siti: concorda con il cliente come condividerlo.
- Con il servizio A365, l'assessment Microsoft invia a GitHub Models il testo delle righe per generare sintesi AI, usando il token di `gh`. Dichiaralo al cliente.
- Il login usa codici dispositivo che scadono dopo 120 secondi: apri la pagina di accesso prima di premere Invio.
