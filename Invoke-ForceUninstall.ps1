<#
.SYNOPSIS
    Force-uninstalls stubborn software from a Windows host and triggers an
    SCCM compliance re-evaluation.

.DESCRIPTION
    Designed for cases where a standard uninstall has already failed both
    automatically (via SCCM) and manually. The script:

      1. Terminates all running processes whose name matches the software keyword
      2. Queries both 32-bit and 64-bit registry uninstall hives for matching entries
      3. Runs the uninstaller silently — handles both MSI (/X /qn) and EXE (/S) formats
      4. Verifies the registry entry is gone and reports success or failure per product
      5. Triggers an SCCM Machine Policy refresh and re-evaluates all Configuration
         Baselines so the management server reflects the new state immediately

    Originally written to remediate Google Chrome installations that resisted
    automated and manual removal across a fleet of managed Windows endpoints.

.PARAMETER SoftwareKeyword
    String used to match process names and registry DisplayName entries.
    Accepts wildcards in registry lookups (e.g. "Chrome", "Google", "Firefox").
    Default: "Google"

.PARAMETER ProcessKeywords
    One or more process-name substrings to terminate before uninstalling.
    Default: @("Chrome", "Google")

.EXAMPLE
    # Run locally on the target machine
    .\Invoke-ForceUninstall.ps1

.EXAMPLE
    # Specify a different application
    .\Invoke-ForceUninstall.ps1 -SoftwareKeyword "Firefox" -ProcessKeywords "Firefox"

.NOTES
    Requirements:
      - Must be run locally on the target host (or via a remote execution mechanism
        such as SCCM, PsExec, or a WMI process call — see Deploy-Software.ps1)
      - Requires local administrator rights
      - SCCM client (ccm) must be installed for steps 4–5; those steps are skipped
        gracefully if the client is absent
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$SoftwareKeyword  = "Google",
    [string[]]$ProcessKeywords = @("Chrome", "Google")
)

# ---------------------------------------------------------------------------
# Step 1 — Kill matching processes so file locks don't block the uninstaller
# ---------------------------------------------------------------------------

foreach ($keyword in $ProcessKeywords) {
    $procs = Get-WmiObject Win32_Process -Filter "name like '%$keyword%'"
    if ($procs) {
        Write-Host "Terminating $($procs.Count) process(es) matching '$keyword'..." -ForegroundColor Yellow
        $procs | ForEach-Object {
            Write-Verbose "  Terminating PID $($_.ProcessId) — $($_.Name)"
            $_.Terminate() | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Step 2 — Find all matching entries in the registry uninstall hives
# ---------------------------------------------------------------------------

$uninstallHives = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

$found = Get-ChildItem -Path $uninstallHives -ErrorAction SilentlyContinue |
         Get-ItemProperty |
         Where-Object { $_.DisplayName -like "*$SoftwareKeyword*" }

if (-not $found) {
    Write-Host "$SoftwareKeyword — NOT INSTALLED" -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------
# Step 3 — Uninstall each matching product
# ---------------------------------------------------------------------------

foreach ($entry in $found) {
    $displayName     = $entry.DisplayName
    $uninstallString = $entry.UninstallString

    Write-Host "`nUninstalling: $displayName" -ForegroundColor Cyan
    Write-Verbose "  UninstallString: $uninstallString"

    if (-not $uninstallString) {
        Write-Warning "  No UninstallString found for '$displayName' — skipping."
        continue
    }

    try {
        if ($uninstallString -match '^MsiExec\.exe') {
            # MSI product — swap /I (install) for /X (remove) and run quietly
            $args = $uninstallString -replace 'MsiExec\.exe\s*', ''
            $args = $args -replace '/I', '/X'
            Start-Process -Wait -FilePath "MsiExec.exe" -ArgumentList "$args /qn"
        }
        else {
            # EXE installer — pass silent flag
            Start-Process -Wait -FilePath $uninstallString -ArgumentList "/S"
        }
    }
    catch {
        Write-Warning "  Error launching uninstaller for '$displayName': $_"
        continue
    }

    # Step 3b — Verify removal by re-checking the registry
    $stillPresent = Get-ChildItem -Path $uninstallHives -ErrorAction SilentlyContinue |
                    Get-ItemProperty |
                    Where-Object { $_.DisplayName -like $displayName }

    if ($stillPresent) {
        Write-Host "  $displayName — UNINSTALL FAILED" -ForegroundColor Red
    }
    else {
        Write-Host "  $displayName — UNINSTALL SUCCESS" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Trigger SCCM Machine Policy refresh
#           Prompts the management point to push updated policy immediately,
#           so the server registers the removal without waiting for the next
#           scheduled inventory cycle.
# ---------------------------------------------------------------------------

$sccmAvailable = Get-WmiObject -Namespace "root\ccm" -Class "SMS_Client" `
                                -ErrorAction SilentlyContinue

if ($sccmAvailable) {
    Write-Host "`nTriggering SCCM Machine Policy refresh..." -ForegroundColor Cyan
    try {
        # Schedule ID 00000000-0000-0000-0000-000000000121 = Machine Policy Retrieval & Evaluation
        Invoke-WmiMethod -Namespace "root\ccm" -Class "SMS_CLIENT" `
                         -Name "TriggerSchedule" `
                         -ArgumentList "{00000000-0000-0000-0000-000000000121}" `
                         -ErrorAction Stop | Out-Null
        Write-Host "  Policy refresh triggered." -ForegroundColor Green
    }
    catch {
        Write-Warning "  Could not trigger SCCM policy refresh: $_"
    }

    # ---------------------------------------------------------------------------
    # Step 5 — Re-evaluate all Configuration Baselines
    #           Forces immediate compliance evaluation so the dashboard reflects
    #           the current state rather than waiting for the next scheduled scan.
    # ---------------------------------------------------------------------------

    Write-Host "Re-evaluating SCCM Configuration Baselines..." -ForegroundColor Cyan
    try {
        $baselines = Get-WmiObject -Namespace "root\ccm\dcm" `
                                   -Class "SMS_DesiredConfiguration" `
                                   -ErrorAction Stop

        if ($baselines) {
            foreach ($baseline in $baselines) {
                Write-Verbose "  Evaluating baseline: $($baseline.Name) v$($baseline.Version)"
                ([wmiclass]"\\$env:COMPUTERNAME\root\ccm\dcm:SMS_DesiredConfiguration").TriggerEvaluation(
                    $baseline.Name,
                    $baseline.Version
                ) | Out-Null
            }
            Write-Host "  $($baselines.Count) baseline(s) re-evaluated." -ForegroundColor Green
        }
        else {
            Write-Host "  No baselines found." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "  Could not evaluate baselines: $_"
    }
}
else {
    Write-Host "`nSCCM client not detected — skipping policy refresh and baseline evaluation." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Cyan
