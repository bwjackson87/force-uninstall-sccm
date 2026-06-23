---
> **Security & Sanitization Notice:** This repository contains sanitized, lab-safe code and documentation. It does not include proprietary, classified, sensitive, or employer-owned data. Hostnames, domains, usernames, IP addresses, and operational details are fictionalized or generalized. See [SECURITY_NOTICE.md](SECURITY_NOTICE.md) for full details.
---

# Force Uninstall with SCCM Compliance Reset

## Overview
A PowerShell script for forcibly removing stubborn software from Windows endpoints when standard uninstall methods — Add/Remove Programs, SCCM application deployment, and vendor uninstallers — have all already failed. After removal, it triggers an SCCM Machine Policy refresh and re-evaluates all Configuration Baselines so the management console reflects the correct compliance state immediately, without waiting for the next scheduled scan.

## Problem It Solves
In managed enterprise environments, software removals occasionally get completely stuck. The application's own uninstaller fails silently, SCCM continues to report the software as installed, and manual removal through the Control Panel either errors out or appears to succeed but leaves behind registry entries that keep it showing as installed. This script was written to break that cycle by bypassing the uninstaller dependency entirely — reading uninstall metadata directly from the registry, terminating all related processes first to clear file locks, and forcing the management agent to re-evaluate compliance immediately after removal.

## Key Features
- Kills all related processes before uninstall to clear file and registry locks
- Discovers installed products by registry keyword match — no hardcoded GUIDs
- Handles both MSI and EXE installer types with correct silent-removal flags
- Verifies removal by re-querying the registry after each product
- Triggers SCCM Machine Policy refresh and Configuration Baseline re-evaluation post-removal
- Gracefully skips SCCM steps if the SCCM client is not present
- Accepts `-SoftwareKeyword` and `-ProcessKeywords` parameters — works for any application

## Technologies Used
- PowerShell 5.1+
- Windows Registry (`HKLM:\SOFTWARE\...\Uninstall`)
- WMI (`Win32_Process`) for process termination
- `MsiExec.exe` and EXE silent-uninstall invocation
- SCCM Client WMI namespace (`root\CCM`)

## Example Use Case
A managed enterprise endpoint has a version of Google Chrome that failed to uninstall through SCCM three times. The SCCM console still reports it as installed, blocking deployment of the approved version. Running this script locally (or delivered via SCCM script, PsExec, or WMI remote process creation) terminates all Chrome processes, removes the application via its registry-sourced MSI GUID, and forces SCCM to re-evaluate compliance — the console shows the application as absent within minutes, unblocking the redeployment.

## How to Run

Run directly on the target host — locally, via SCCM script delivery, PsExec, or WMI remote process invocation:

```powershell
# Default — targets all "Google" products
.\Invoke-ForceUninstall.ps1

# Target a different application
.\Invoke-ForceUninstall.ps1 -SoftwareKeyword "Firefox" -ProcessKeywords "Firefox"

# Verbose output — shows each PID terminated and each baseline evaluated
.\Invoke-ForceUninstall.ps1 -Verbose
```

| Parameter | Default | Description |
|---|---|---|
| `-SoftwareKeyword` | `"Google"` | Substring matched against registry `DisplayName` entries |
| `-ProcessKeywords` | `@("Chrome","Google")` | Process name substrings to terminate before uninstalling |

## Example Output

```
Terminating 3 process(es) matching 'Chrome'...

Uninstalling: Google Chrome
  Google Chrome — UNINSTALL SUCCESS

Triggering SCCM Machine Policy refresh...
  Policy refresh triggered.
Re-evaluating SCCM Configuration Baselines...
  4 baseline(s) re-evaluated.

Done.
```

## Security Notes
- Requires **local administrator rights** on the target host
- Use a dedicated service account with scoped admin rights rather than domain admin credentials for bulk delivery
- The installer command is constructed from registry data — validate the target keyword to avoid matching and removing unintended software
- Authorized use only — run only against systems and software you are authorized to manage

## Lessons Learned
- EXE uninstallers require passing `/S` for silent removal, while MSI products require replacing `/I` (install) with `/X` (remove) in the uninstall string — treating all products the same causes roughly half of removals to fail or prompt interactively
- Searching both `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` and the `Wow6432Node` equivalent is necessary — 32-bit applications installed on 64-bit Windows register only in the 32-bit hive, and will be missed without it
- SCCM's next scheduled compliance scan can be hours away — triggering `TriggerEvaluation()` on each `SMS_DesiredConfiguration` baseline immediately after removal eliminates the console lag that causes re-deployment attempts to be blocked by stale data
- Pairing this script with [remote-software-deploy](https://github.com/bwjackson87/remote-software-deploy) enables a full remove-then-redeploy workflow without requiring WinRM on the target
