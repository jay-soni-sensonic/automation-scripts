# ERPNext Attendance Automation - Arguments Reference

> Script: `automation-scripts\erp-next\ERPNext-Attendance.ps1`
> Requires: PowerShell 5.1+ on Windows

---

## Quick Start

### Download files

```powershell
$dest = "$env:USERPROFILE\Documents\automation-scripts\erp-next"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$base = "https://raw.githubusercontent.com/jay-soni-sensonic/automation-scripts/refs/heads/main/erp-next"
$files = @("ERPNext-Attendance.ps1","holidays.json","leaves.json","working_weekend_dates.json")
foreach ($f in $files) { Invoke-WebRequest -Uri "$base/$f" -OutFile "$dest\$f" }
cd $dest
```

### First-time configure and run

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1
```

The wizard prompts for URL, username, password, device ID, API method, log
retention period, and scheduled task times. Settings are saved to
`erpnext-config.json` (password encrypted via Windows DPAPI).

---

## Script Arguments

| Argument | Type | Description |
|---|---|---|
| `-Reconfigure` | Switch | Re-run the setup wizard to update saved connection settings |
| `-AddScheduler` | Switch | Register Windows Scheduled Tasks for automatic check-in/out |
| `-RemoveScheduler` | Switch | Remove all Scheduled Tasks registered by this script |
| `-Force` | Switch | Skip the holiday/weekend guard and run regardless of the day |

---

## Usage Examples

```powershell
# Normal run - auto decides Check-IN or Check-OUT based on today's log
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1

# Update connection settings
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -Reconfigure

# Register Windows Scheduled Tasks (logon check-in + 18:00 check-out)
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -AddScheduler

# Remove all scheduled tasks created by this script
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -RemoveScheduler

# Force run on a holiday or weekend (manual override)
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -Force
```

---

## Configuration Files

All files live in the `erp-next\` directory alongside the script.

| File | Purpose | In repo |
|---|---|---|
| `erpnext-config.json` | Connection settings, scheduler times, log retention | No (machine-only) |
| `erpnext-attendance-log.json` | Full request/response log | No (machine-only) |
| `holidays.json` | Public holidays - array of `"YYYY-MM-DD"` dates | Yes |
| `leaves.json` | Personal leave dates - array of `"YYYY-MM-DD"` | No (machine-only) |
| `working_weekend_dates.json` | Weekend dates treated as working days | Yes |

### erpnext-config.json fields

| Field | Default | Description |
|---|---|---|
| `BaseUrl` | - | ERPNext instance URL e.g. `https://erpnext.example.com` |
| `Username` | - | Login email address |
| `EncryptedPassword` | - | Windows DPAPI blob - set by the script, do not edit |
| `AttendanceDeviceId` | `"1"` | Device ID sent with the attendance log request |
| `AttendanceEndpoint` | `"kaynes.kaynes_hr.api.log_attendance"` | Frappe API method path |
| `LogRetentionDays` | `60` | Days before log entries are auto-pruned |
| `CheckInTime` | `"09:00"` | Daily scheduled task check-in trigger time (24h HH:mm) |
| `CheckOutTime` | `"18:00"` | Daily scheduled task check-out trigger time (24h HH:mm) |

### holidays.json example

```json
[
  "2026-01-01",
  "2026-01-26",
  "2026-08-15",
  "2026-12-25"
]
```

### working_weekend_dates.json example

```json
[
  "2026-04-06",
  "2026-04-13"
]
```

---

## Scheduled Tasks

Three tasks are registered by `-AddScheduler`:

| Task Name | Trigger | Purpose |
|---|---|---|
| `ERPNext-Attendance-CheckIn` | At user logon | Check-IN when the computer starts / user logs on |
| `ERPNext-Attendance-CheckIn-Daily` | Daily at `CheckInTime` | Backup trigger if logon event was already past |
| `ERPNext-Attendance-CheckOut` | Daily at `CheckOutTime` | Auto Check-OUT |

All tasks respect the holiday/weekend rules - they silently skip on non-working days.

To update check-in/check-out times:
1. Edit `CheckInTime` / `CheckOutTime` in `erpnext-config.json`
2. Re-run from the `erp-next` folder: `.\ERPNext-Attendance.ps1 -AddScheduler`

To view or manually trigger tasks, open **Task Scheduler** (`taskschd.msc`).

---

## Automatic IN / OUT Logic

The script reads today's successful entries from `erpnext-attendance-log.json`:

- No entry today => **Check-IN**
- Last entry was Check-IN => **Check-OUT**
- Last entry was Check-OUT => **Check-IN** (re-entry / overtime scenario)

---

## Security Notes

- The password is stored using **Windows DPAPI** (`ConvertFrom-SecureString`
  without a `-Key`). It can only be decrypted by the **same Windows user
  account on the same machine**.
- `erpnext-config.json` and `erpnext-attendance-log.json` are gitignored to
  prevent accidental commits of credentials or personal data.
- Plain-text password is held in memory only for the duration of the login
  HTTP call, then zeroed via `Marshal.ZeroFreeBSTR`.
