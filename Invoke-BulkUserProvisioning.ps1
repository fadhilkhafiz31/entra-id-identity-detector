<#
.SYNOPSIS
    Bulk user provisioning demo using Microsoft Graph PowerShell SDK.

.DESCRIPTION
    Reads a CSV of new hires, creates each user in Entra ID, adds them to a
    department-mapped group, checks license availability, and logs the result
    of every step. Built as a companion automation demo for the Entra ID
    identity-security project (SecureBank-Entra companion piece).

    Honest scope note: this is a demo script, not a production tool. No retry
    logic, no rollback on partial failure, no input validation beyond what
    New-MgUser enforces itself. Good enough to show the automation pattern
    end-to-end; a production version would add those.

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Scopes needed: User.ReadWrite.All, Group.ReadWrite.All, Directory.Read.All
#>

param(
    [string]$CsvPath = ".\onboarding_users.csv",
    [string]$LogPath = ".\provisioning_log.csv",
    [string]$DefaultPassword = "<set-at-runtime>"
)

# Force every cmdlet to throw a terminating error on failure, so try/catch
# below actually catches real failures instead of silently continuing past
# a non-terminating error (the Microsoft.Graph module's default behavior).
$ErrorActionPreference = "Stop"

# --- Step 1: Connect ---------------------------------------------------
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.Read.All"

# Map department -> target group display name. Adjust to match the groups
# that actually exist in the tenant before running.
$DepartmentGroupMap = @{
    "Marketing" = "Marketing-Users"
    "Finance"   = "Finance-Users"
    "IT"        = "IT-Users"
    "Sales"     = "Sales-Users"
    "HR"        = "HR-Users"
}

# --- Step 2: Load CSV ----------------------------------------------------
if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV not found at $CsvPath"
    return
}
$users = Import-Csv -Path $CsvPath
Write-Host "Loaded $($users.Count) users from $CsvPath" -ForegroundColor Cyan

# Pre-check license SKUs available in the tenant (so we don't fail silently
# per-user later). If the lab tenant has no real M365 SKUs, this will be
# empty - that's expected for a trial/lab tenant, so licensing is skipped
# gracefully rather than erroring.
$availableSkus = Get-MgSubscribedSku -ErrorAction SilentlyContinue
if (-not $availableSkus) {
    Write-Host "No subscribed SKUs found in this tenant - licensing step will be skipped." -ForegroundColor Yellow
}

$results = @()

# --- Step 3-5: Loop through users: create, group, license -----------------
foreach ($u in $users) {

    $logEntry = [PSCustomObject]@{
        DisplayName        = $u.DisplayName
        UserPrincipalName  = $u.UserPrincipalName
        Department         = $u.Department
        LicenseType        = $u.LicenseType
        UserCreated        = $false
        GroupAssigned      = $false
        LicenseAssigned    = $false
        Error              = ""
    }

    try {
        # --- Create user ---
        $mailNickname = ($u.UserPrincipalName -split "@")[0] -replace "\.", ""
        $passwordProfile = @{
            Password                      = $DefaultPassword
            ForceChangePasswordNextSignIn = $true
        }

        $newUser = New-MgUser -DisplayName $u.DisplayName `
            -UserPrincipalName $u.UserPrincipalName `
            -MailNickname $mailNickname `
            -AccountEnabled `
            -PasswordProfile $passwordProfile `
            -Department $u.Department

        $logEntry.UserCreated = $true
        Write-Host "[CREATED] $($u.DisplayName) -> $($u.UserPrincipalName)" -ForegroundColor Green

        # Brief pause: a brand-new directory object isn't always immediately
        # resolvable as a $ref target elsewhere in Graph (replication lag).
        # Without this, New-MgGroupMemberByRef intermittently fails with
        # "Invalid target for navigation property update."
        Start-Sleep -Seconds 5

        # --- Assign to department group ---
        $groupName = $DepartmentGroupMap[$u.Department]
        if ($groupName) {
            $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
            if ($group) {
                New-MgGroupMemberByRef -GroupId $group.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($newUser.Id)"
                $logEntry.GroupAssigned = $true
                Write-Host "  -> Added to group: $groupName" -ForegroundColor Green
            } else {
                Write-Host "  -> Group '$groupName' not found in tenant, skipping." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  -> No group mapping for department '$($u.Department)', skipping." -ForegroundColor Yellow
        }

        # --- License check + assign (only if a matching SKU exists) ---
        if ($availableSkus) {
            $matchingSku = $availableSkus | Where-Object { $_.SkuPartNumber -like "*$($u.LicenseType -replace ' ', '')*" }
            if ($matchingSku) {
                Set-MgUserLicense -UserId $newUser.Id `
                    -AddLicenses @{SkuId = $matchingSku.SkuId} `
                    -RemoveLicenses @()
                $logEntry.LicenseAssigned = $true
                Write-Host "  -> License assigned: $($u.LicenseType)" -ForegroundColor Green
            } else {
                Write-Host "  -> No matching SKU for '$($u.LicenseType)', skipping license." -ForegroundColor Yellow
            }
        }
    }
    catch {
        $logEntry.Error = $_.Exception.Message
        Write-Host "[FAILED] $($u.DisplayName): $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $logEntry
}

# --- Step 6: Log output ---------------------------------------------------
$results | Export-Csv -Path $LogPath -NoTypeInformation
Write-Host "`nDone. Log written to $LogPath" -ForegroundColor Cyan
$results | Format-Table -AutoSize
