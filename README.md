# Force Uninstall with SCCM Compliance Reset

A PowerShell script for forcibly removing stubborn software from Windows endpoints when standard uninstall methods — both automated (SCCM) and manual — have already failed. After removal it triggers an SCCM Machine Policy refresh and re-evaluates all Configuration Baselines so the management console reflects the correct state immediately.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell) ![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey?logo=windows) ![SCCM](https://img.shields.io/badge/SCCM-Optional-orange) ![License](https://img.shields.io/badge/License-MIT-green)

## Problem This Solves

In managed enterprise environments, software removals occasionally get stuck — the application's own uninstaller fails silently, SCCM reports the software as still installed, and manual uninstall through Add/Remove Programs either errors out or appears to succeed but leaves registry entries behind.

This script was written to remediate exactly that scenario across a fleet of managed Windows endpoints. It works by:

1. **Killing all related processes** before attempting removal, eliminating file-lock failures
2. **Reading uninstall metadata directly from the registry** rather than relying on the application's own remove entry in Programs & Features
3. **Handling both MSI and EXE installers** with the correct silent-uninstall flags
4. **Verifying removal** by re-querying the registry after each product
5. **Forcing SCCM to re-check compliance** immediately rather than waiting for the next scheduled inventory cycle

## Requirements

| Requirement | Detail |
|-------------|--------|
| PowerShell | 5.1 or later |
| Permissions | Local administrator on the target host |
| SCCM client | Optional — steps 4–5 are skipped gracefully if not installed |

## Usage

Run directly on the target host (locally, via SCCM script delivery, PsExec, or a WMI process invocation):

```powershell
# Default — targets all "Google" products
.\Invoke-ForceUninstall.ps1

# Target a different application
.\Invoke-ForceUninstall.ps1 -SoftwareKeyword "Firefox" -ProcessKeywords "Firefox"

# Verbose output (shows each PID terminated and baseline evaluated)
.\Invoke-ForceUninstall.ps1 -Verbose
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SoftwareKeyword` | `"Google"` | Substring matched against registry `DisplayName` entries |
| `-ProcessKeywords` | `@("Chrome","Google")` | Process name substrings to terminate before uninstalling |

### Example Output

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

## How It Works

### Step 1 — Process termination
Queries `Win32_Process` via WMI for any running process whose name contains the keyword and calls `Terminate()`. This releases file handles that would otherwise block the uninstaller.

### Step 2 — Registry discovery
Searches both the 64-bit and 32-bit uninstall hives:
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
- `HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall`

### Step 3 — Silent uninstall (MSI and EXE)
| Installer type | Detection | Command |
|----------------|-----------|---------|
| MSI | `UninstallString` starts with `MsiExec.exe` | `MsiExec.exe /X {GUID} /qn` |
| EXE | All others | `<uninstaller.exe> /S` |

For MSI products, `/I` (install) in the uninstall string is replaced with `/X` (remove).

### Step 4 — SCCM Machine Policy refresh
Invokes `SMS_CLIENT.TriggerSchedule` with the **Machine Policy Retrieval & Evaluation** schedule ID (`{00000000-0000-0000-0000-000000000121}`). This tells the SCCM agent to immediately fetch updated policy from the management point.

### Step 5 — Configuration Baseline re-evaluation
Enumerates all `SMS_DesiredConfiguration` objects and calls `TriggerEvaluation()` on each. This forces the SCCM client to report current compliance state without waiting for its next scheduled scan window.

## Pairing with Remote Deployment

This script is designed to run **locally** on the target. To push it to remote hosts, use [Deploy-Software.ps1](https://github.com/bwjackson87/remote-software-deploy) or a similar WMI-based remote execution mechanism to invoke it without requiring WinRM.

## License

MIT — see [LICENSE](LICENSE) for details.
