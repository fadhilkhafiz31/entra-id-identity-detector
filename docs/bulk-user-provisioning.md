# Bulk User Provisioning — How the Three Files Work Together

**Scope note:** this is a *standalone admin-automation exercise*. It is **not** part of the
Entra ID detection work in `detector.py`. Nothing here feeds the detector and the detector
reads nothing from here. The only things they share are the tenant and the fact that both
talk to Microsoft Graph. Kept in this repo for convenience, documented separately so the
boundary stays clear.

---

## The three files at a glance

| File | Role | Who writes it |
|---|---|---|
| `onboarding_users.csv` | **Input.** The list of new hires to create. | You, by hand |
| `Invoke-BulkUserProvisioning.ps1` | **The engine.** Reads the input, does the work in Entra ID. | You, once |
| `provisioning_log.csv` | **Output.** What actually happened, per user, per step. | The script, on every run |

It is a straight pipeline — one in, one out:

```
onboarding_users.csv  ──►  Invoke-BulkUserProvisioning.ps1  ──►  provisioning_log.csv
      (5 rows)                   (loops 5 times)                     (5 rows + results)
                                        │
                                        ▼
                               Microsoft Entra ID
                          (users created, groups joined)
```

Both filenames are **parameters**, not hardcoded paths — see
[`Invoke-BulkUserProvisioning.ps1:21-25`](../Invoke-BulkUserProvisioning.ps1#L21-L25). You can
point the script at a different CSV without editing it:

```powershell
.\Invoke-BulkUserProvisioning.ps1 -CsvPath .\contractors.csv -LogPath .\contractors_log.csv
```

---

## File 1 — `onboarding_users.csv` (the input)

```csv
DisplayName,UserPrincipalName,Department,LicenseType
Alice Tan,alice.tan@contoso.onmicrosoft.com,Marketing,Business Standard
...
```

Four columns, and **each one is consumed by a different step of the script**. That is the
whole design: the CSV is not just data, it is the instruction set.

| Column | Used for | Where |
|---|---|---|
| `DisplayName` | The name shown in Entra ID / Teams / Outlook | `New-MgUser -DisplayName` |
| `UserPrincipalName` | The login identity, **and** the source of `mailNickname` | `New-MgUser -UserPrincipalName` |
| `Department` | Looked up in a map to decide which group to join | `$DepartmentGroupMap[...]` |
| `LicenseType` | Matched against the tenant's available SKUs | `Set-MgUserLicense` |

The header row matters. `Import-Csv` turns each header into a property name, so
`$u.DisplayName` works *only* because the header literally says `DisplayName`. Rename a
column in the CSV and the matching line in the script silently gets `$null`.

---

## File 2 — `Invoke-BulkUserProvisioning.ps1` (the engine)

### Setup, before the loop

**Connect** — [line 34](../Invoke-BulkUserProvisioning.ps1#L34). `Connect-MgGraph` with three
scopes. Each scope maps to one thing the script does:

- `User.ReadWrite.All` → create users
- `Group.ReadWrite.All` → add members to groups
- `Directory.Read.All` → read groups and license SKUs

Ask for only what you use. This is least-privilege in practice: if the script only needed to
*read*, requesting `.ReadWrite.All` would be an over-grant.

**`$ErrorActionPreference = "Stop"`** — [line 30](../Invoke-BulkUserProvisioning.ps1#L30). This is
the most important line in the file and the easiest to overlook. By default, many cmdlets emit
a *non-terminating* error: they print red text and **keep going**. A `try/catch` does not catch
those. Setting `Stop` promotes them to terminating errors so `catch` actually fires. Without
this line, a failed user would look like a success in the log.

**The department map** — [lines 38-44](../Invoke-BulkUserProvisioning.ps1#L38-L44). A hashtable
translating a CSV value into a real group name:

```powershell
$DepartmentGroupMap = @{ "Marketing" = "Marketing-Users"; ... }
```

Why a map instead of putting the group name in the CSV? Because the CSV is written by whoever
does HR onboarding, and they know "Marketing" but not your group naming convention. The map is
the translation layer between *business language* and *directory language*. Change your naming
scheme and you edit one hashtable, not every CSV ever.

**Pre-check SKUs** — [lines 58-61](../Invoke-BulkUserProvisioning.ps1#L58-L61).
`Get-MgSubscribedSku` is called **once, before the loop**, not once per user. The list of
licenses a tenant owns does not change mid-run, so fetching it 5 times would be 4 wasted API
calls. With 5 users that is trivial; with 500 it is the difference between finishing and
getting throttled.

### Inside the loop — per user

For each row, the script builds a **log object first**, then tries the work:

```powershell
$logEntry = [PSCustomObject]@{
    DisplayName = ...; UserCreated = $false; GroupAssigned = $false; LicenseAssigned = $false; Error = ""
}
```

Note the three `$false` defaults. The object is created **pessimistically** — everything failed
until proven otherwise. Each successful step flips its own flag to `$true`. This is why a crash
halfway through still produces a meaningful log row instead of a blank one.

**Step A — create the user** ([lines 81-95](../Invoke-BulkUserProvisioning.ps1#L81-L95))

```powershell
$mailNickname = ($u.UserPrincipalName -split "@")[0] -replace "\.", ""
```

`alice.tan@...` → split on `@` → `alice.tan` → strip dots → **`alicetan`**. Entra requires a
`mailNickname` and dislikes certain characters, so it is derived rather than asked for.

```powershell
$passwordProfile = @{ Password = $DefaultPassword; ForceChangePasswordNextSignIn = $true }
```

`ForceChangePasswordNextSignIn = $true` is the part that makes a shared default password
*almost* acceptable — the user must change it on first login, so the known value has a short
life. (See the security notes at the bottom; "almost" is doing real work there.)

**The 5-second sleep** ([line 101](../Invoke-BulkUserProvisioning.ps1#L101)) — this is the kind of
thing you only learn by hitting it. Entra ID is **eventually consistent**. `New-MgUser` returns
an object with an `Id`, but that object has not finished replicating across Microsoft's
directory replicas. Immediately using that `Id` as a `$ref` target in the next call fails with
*"Invalid target for navigation property update"* — intermittently, which is the worst kind of
failure. The sleep is a crude fix; a production script would retry with backoff instead of
guessing a duration.

**Step B — join the department group** ([lines 104-116](../Invoke-BulkUserProvisioning.ps1#L104-L116))

Three-stage guard, and each stage handles a different real-world problem:

1. `if ($groupName)` — is this department even in the map? Handles an HR typo or a new department.
2. `if ($group)` — does that group actually exist in the tenant? Handles a map that drifted out of date.
3. Only then: `New-MgGroupMemberByRef`

Both misses print a yellow warning and **continue** rather than throwing. A missing group is a
configuration gap, not a reason to abandon the remaining four users.

The `-OdataId` parameter is worth understanding, because it looks strange:

```powershell
-OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($newUser.Id)"
```

Graph does not take "add user X to group Y" as two IDs. Group membership is a *navigation
property*, and you add to it by POSTing a **URL that points at the object**. You are handing
Graph a reference, not an ID. Hence `ByRef` in the cmdlet name, and hence why replication lag
breaks it — Graph has to resolve that URL, and it cannot resolve what has not replicated.

**Step C — assign a license** ([lines 119-130](../Invoke-BulkUserProvisioning.ps1#L119-L130))

Wrapped in `if ($availableSkus)`, so a tenant owning no licenses skips the whole block instead
of erroring five times. The match is fuzzy:

```powershell
$availableSkus | Where-Object { $_.SkuPartNumber -like "*$($u.LicenseType -replace ' ', '')*" }
```

`"Business Standard"` → `"BusinessStandard"` → look for a SKU part number containing that.
**This is the weakest link in the script** and your log proves it — see below.

**The `catch`** ([lines 132-135](../Invoke-BulkUserProvisioning.ps1#L132-L135)) — records the
exception message into `$logEntry.Error` and moves to the next user. The loop is *resilient*:
user 3 failing does not stop users 4 and 5. What it is **not** is *transactional* — a user
created but not grouped stays half-provisioned, and nothing rolls back.

### After the loop

```powershell
$results | Export-Csv -Path $LogPath -NoTypeInformation
```

`-NoTypeInformation` suppresses the `#TYPE System.Management.Automation.PSCustomObject` junk
line that older PowerShell writes at the top of a CSV. Without it, Excel and `Import-Csv` both
get confused.

---

## File 3 — `provisioning_log.csv` (the output)

```csv
"DisplayName","UserPrincipalName","Department","LicenseType","UserCreated","GroupAssigned","LicenseAssigned","Error"
"Alice Tan","alice.tan@...","Marketing","Business Standard","True","True","False",""
"Rizal Hakim","rizal.hakim@...","Finance","Business Standard","True","True","False",""
"Siti Aminah","siti.aminah@...","IT","Business Premium","True","True","False",""
"Daniel Wong","daniel.wong@...","Sales","Business Standard","True","True","False",""
"Nur Hidayah","nur.hidayah@...","HR","Business Standard","True","True","False",""
```

**The log is the input CSV plus four result columns.** That is deliberate — you can read one
row and see both what was requested and what was delivered, without cross-referencing two files.

### Reading this specific run

- **`UserCreated = True` ×5** — all five accounts exist in Entra ID now.
- **`GroupAssigned = True` ×5** — all five groups (`Marketing-Users`, `Finance-Users`,
  `IT-Users`, `Sales-Users`, `HR-Users`) existed and accepted the member. Both the map and the
  tenant were in sync, and the 5-second sleep was long enough.
- **`LicenseAssigned = False` ×5** — nothing was licensed.
- **`Error = ""` ×5** — no exceptions were thrown. Nothing *failed*; the licensing step was
  *skipped*.

That last pair is the interesting part, and distinguishing "skipped" from "failed" is the main
skill this log teaches. Two different code paths produce `LicenseAssigned = False` with an empty
`Error`:

1. The tenant owns no SKUs → `$availableSkus` is empty → the whole block is skipped (line 119)
2. The tenant owns SKUs, but none matched the `-like` pattern → skipped per-user (line 128)

The CSV alone cannot tell you which. The **console output** can — path 1 prints *"No subscribed
SKUs found in this tenant"* once, path 2 prints *"No matching SKU for 'Business Standard'"* five
times. This is a genuine gap in the logging: the log should record *why* a step was skipped, not
just that it did not happen.

Worth knowing for next time: real Microsoft SKU part numbers look like `O365_BUSINESS_PREMIUM`,
`SPB`, `ENTERPRISEPACK` — **not** `BusinessStandard`. So even in a fully licensed tenant, this
`-like` match would likely miss. Run `Get-MgSubscribedSku | Select SkuPartNumber, SkuId` against
your tenant and either put the real part numbers in the CSV, or map friendly names to SKU IDs
the same way departments are mapped to groups. The license step was never going to work as
written — the lab tenant just hid that behind the same `False`.

---

## The pattern worth taking away

Strip away the Entra specifics and this is a shape you will reuse constantly:

1. **Declarative input** — a CSV describing desired state, editable by a non-engineer
2. **A translation layer** — the hashtable turning business vocabulary into system vocabulary
3. **Independent per-item loop** — one failure does not kill the batch
4. **Pessimistic result object** — default to failure, flip flags on proven success
5. **Structured output** — input + outcome in one row, machine-readable for the next step
6. **Pre-fetch what does not change** — one SKU call, not N

Steps 3-5 together are what make a batch job *operable*: you can rerun it, diff the logs, and
answer "did Rizal get his group?" without logging into a portal.

---

## Known gaps (acknowledged in the script's own header)

Honest about what is missing, which is the right instinct for a demo:

- **No retry logic** — the 5-second sleep is a guess, not a retry. Replication lag over 5
  seconds still fails.
- **No rollback** — a user created but not grouped stays half-provisioned.
- **No input validation** — a malformed UPN or empty `DisplayName` only fails once Graph rejects it.
- **Not idempotent** — rerunning on the same CSV tries to recreate existing users and throws
  "user already exists". A production version would check first, or use upsert semantics.
- **`$results += $logEntry`** rebuilds the whole array every iteration — O(n²). Fine at 5 users,
  noticeable at 5,000. `$results = [System.Collections.Generic.List[object]]::new()` plus
  `.Add()` is the fix.
- **`Get-MgGroup -Filter` can return multiple groups.** If two groups share a display name,
  `$group.Id` becomes an *array* and the `$ref` URL becomes garbage. Add
  `| Select-Object -First 1` or filter on a unique attribute. Same issue with `$matchingSku.SkuId`.

## Security notes

- **`$DefaultPassword = "<set-at-runtime>"` is hardcoded as a parameter default**
  ([line 24](../Invoke-BulkUserProvisioning.ps1#L24)). `ForceChangePasswordNextSignIn` limits the
  window, but until each user signs in, five accounts in a live tenant share a password that is
  sitting in a file. Better: generate a random password per user, or pass it as a
  `[SecureString]`. Those five accounts likely still have it — rotate or delete them.
- **`provisioning_log.csv` contains real UPNs from a live tenant.** Fine for a personal lab;
  think twice before committing it to a public repo. Add it to `.gitignore` if this repo ever
  goes public.
