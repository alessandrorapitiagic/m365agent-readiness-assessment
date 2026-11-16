# Sandbox guide

## 1. Purpose

This guide tells you how to run the assessment in the Docker sandbox.
The sandbox is a clean Linux container.
It keeps your PC clean: it installs nothing on Windows except the Docker image.

This text follows the style of ASD-STE100 (Simplified Technical English).
It is not a certified document.

## 2. What you need

- A Windows PC with Docker Desktop. Docker Desktop must be running.
- PowerShell.
- A copy of this repository.
- The tenant ID or the domain of the customer (example: `contoso.onmicrosoft.com`).
- An account of the customer with the Global Administrator role.
- For Power Platform and Copilot Studio: an account with the Power Platform Administrator role.
- For Agent 365: a GitHub account.
- A web browser.

## 3. How you communicate with the container

You do not use SSH. The container has no SSH server. It has no open network port.

You use Docker to open a terminal in the container. The terminal shows in your PowerShell window.

| Item | How it works |
| --- | --- |
| Terminal | The command `docker exec -it ara-sandbox ara` starts the program `ara` in the container. The text of the program shows in your window. Your keyboard goes to the program. |
| Start script | `start.ps1` does two actions. First, it starts the container in the background (`docker compose up -d --build`). Second, it opens the terminal (`docker exec -it`). |
| End of the terminal | The terminal closes when the program ends or when you press Ctrl+C. The container continues to run in the background. |
| Reports | The folder `sandbox\reports` on your PC is the folder `/home/ara/m365-ara/Reports` in the container. A report that the container writes shows on your PC at once. |
| Credentials | A Docker volume (`ara-home`) keeps the folder `/home/ara/m365-ara`. The file `.env` stays there after the container stops. |
| Network | The container makes outgoing connections to the internet (Microsoft and GitHub). No program connects to the container from outside. |
| Sign-in | You sign in with the browser on your PC. The container shows a code. You type the code on the web page. The browser and the container do not connect to each other. |

These commands help you to control the container:

| Action | Command |
| --- | --- |
| Show the container | `docker ps --filter name=ara-sandbox` |
| Open a shell in the container | `docker exec -it ara-sandbox bash` |
| Copy a file from the container to your PC | `docker cp ara-sandbox:/home/ara/m365-ara/.env .` (do not share this file) |
| Stop the container | `docker compose -f .\sandbox\docker-compose.yml stop` |
| Start the container again | `docker compose -f .\sandbox\docker-compose.yml start` |

## 4. Start the sandbox

1. Open PowerShell.
2. Go to the folder of this repository.
3. Run this command:

   ```powershell
   .\sandbox\start.ps1
   ```

4. Wait. The first start builds the image. This takes several minutes.

The script starts the container and opens a terminal in it (see section 3).

**Result:** the guided procedure starts in the container.

If you see `Avvio della sandbox non riuscito`, start Docker Desktop. Then do this step again.

## 5. Answer the guided procedure

The procedure asks these questions in this order. Press Enter to use the default answer.

1. **Tenant.** Type the tenant ID or the domain of the customer.
2. **Services.** Answer for each service. The default answer is yes.
   - Purview: the default answer is no. Purview needs a browser login. The container has no browser.
3. **Start.** Answer `s` to start the full run.
4. **Patch.** Answer `s` to apply the corrections to the Microsoft code.
   - The default answer is yes.
   - The container needs the correction for the device code login.
   - See the section "Patch" in the README for details.

**Result:** the procedure shows the command and starts the run.

To see the command without a run, use this command in a shell:

```bash
ara --dry-run
```

## 6. Sign in with a device code

The setup of the credentials uses a device code. The code expires after 120 seconds.

1. Open `https://login.microsoft.com/device` in your browser.
2. Sign in with the Global Administrator account of the customer.
3. Keep this page open.
4. In the container, press Enter when the message `Premi Invio quando sei pronto` shows.
5. Copy the code from the container.
6. Type the code on the web page.
7. Accept the sign-in.

**Result:** the script creates the app registration and saves the credentials in the file `.env`.

If the code expires, run `ara` again. Be ready before you press Enter.

## 7. Give the admin consent

The script checks the permissions of the app.

If a permission is missing, the script shows a link.

1. Open the link in your browser.
2. Sign in as Global Administrator.
3. Accept the permissions.

The script waits up to 5 minutes for the consent.

**Result:** the message `Consenso amministrativo verificato` shows.

If the consent is not found in 5 minutes, the script stops. Run `ara` again after the consent.

## 8. Register the app for Power Platform

This step applies when you selected Power Platform or Copilot Studio.

The script tests the Power Platform admin API with the app credentials.

If the API refuses the app (error 403), the script asks you to register the app.

1. Be ready with a Power Platform Administrator account.
2. Press Enter. To skip this step, type `N`, then press Enter.
3. Sign in with a device code. Use the steps in section 6.

**Result:** the message `Accesso alle API Power Platform verificato` shows.

If you skip this step, the Power Platform and Copilot Studio results are partial.

## 9. Sign in for Agent 365

This step applies when you selected Agent 365.

The assessment needs a GitHub login. It uses the login to write the summaries.

1. Follow the instructions of the GitHub CLI in the container.
2. Sign in with a GitHub account.

**Warning:** the assessment sends the text of the A365 rows to GitHub Models. Tell the customer.

Without the GitHub login, the Agent 365 step stops the assessment.
To avoid this, do not select Agent 365.

## 10. Get the reports

The reports are in the folder `sandbox\reports` on your PC.

The container writes each report as a CSV file. The name contains the date and the time.

**Warning:** the CSV file contains names of people and sites. Share it only as the customer agrees.

## 11. Run again

1. Run `.\sandbox\start.ps1`.
2. Answer the questions again.

The credentials stay in a Docker volume. The script does not ask for the setup login again.

To open a shell in the container, run this command:

```powershell
.\sandbox\start.ps1 -Shell
```

## 12. Clean up

1. Delete the app registration in the Entra admin center of the customer.
2. Run this command to delete the container and the credentials:

   ```powershell
   docker compose -f .\sandbox\docker-compose.yml down -v
   ```

The secret of the app expires after 30 days.

**Warning:** `down -v` deletes the file `.env`. The reports in `sandbox\reports` stay on your PC.

## 13. Fix problems

| Problem | Cause | Action |
| --- | --- | --- |
| `Avvio della sandbox non riuscito` | Docker Desktop is not running | Start Docker Desktop. Run the command again. |
| `Authentication timed out after 120 seconds` | You did not enter the code in time | Run `ara` again. Open the device page before you press Enter. |
| `403 Forbidden` for Power Platform | The app is not registered as a management application | Do section 8. Use a Power Platform Administrator account. |
| The run stops at Agent 365 | No GitHub login | Sign in to GitHub, or do not select Agent 365. |
| Purview gives no data | The container has no browser | Run Purview on a Windows PC with the Windows script. |
| Many M365 values show `0` | The Microsoft code uses wrong report columns | Run again with the patch. Answer `s` to the patch question. |
