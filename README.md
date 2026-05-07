# ERPNext Attendance Automation

Automatically logs your Check-IN and Check-OUT to ERPNext every day —
no manual clicks needed. The script runs when your computer starts (Check-IN)
and at a configured time in the evening (Check-OUT). It skips weekends,
public holidays, and leave days automatically.

---

## Table of Contents

1. [What You Need Before Starting](#1-what-you-need-before-starting)
2. [Download the Script](#2-download-the-script)
3. [First-Time Setup](#3-first-time-setup)
4. [Set Up Automatic Scheduling](#4-set-up-automatic-scheduling)
5. [Confirm the Schedule in Task Scheduler](#5-confirm-the-schedule-in-task-scheduler)
6. [Change Check-In / Check-Out Times](#6-change-check-in--check-out-times)
7. [Declare Public Holidays](#7-declare-public-holidays)
8. [Declare Personal Leave](#8-declare-personal-leave)
9. [Working on a Weekend](#9-working-on-a-weekend)
10. [Update ERPNext Credentials](#10-update-erpnext-credentials)
11. [Remove the Scheduled Tasks](#11-remove-the-scheduled-tasks)
12. [Run Manually Any Time](#12-run-manually-any-time)
13. [Common Errors and Fixes](#13-common-errors-and-fixes)

---

## 1. What You Need Before Starting

- A Windows PC (Windows 10 or Windows 11)
- Your ERPNext login credentials:
  - **ERPNext URL** — e.g. `https://erpnext.yourcompany.com`
  - **Username** — your login email address
  - **Password** — your ERPNext password
- Internet connection to reach the ERPNext server
- **No programming knowledge required**

> **Tip:** Keep your ERPNext credentials handy before you start.
> The setup will ask for them once and save them securely.

---

## 2. Download the Script

1. Open **PowerShell** — press `Win + R`, type `powershell`, press Enter
2. Copy the entire block below and paste it into PowerShell with a single right-click, then press Enter:

```powershell
$dest = "$env:USERPROFILE\Documents\automation-scripts\erp-next"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$base = "https://raw.githubusercontent.com/jay-soni-sensonic/automation-scripts/refs/heads/main/erp-next"
$files = @(
    "ERPNext-Attendance.ps1",
    "holidays.json",
    "leaves.json",
    "working_weekend_dates.json"
)
foreach ($f in $files) {
    Invoke-WebRequest -Uri "$base/$f" -OutFile "$dest\$f"
    Write-Host "Downloaded: $f"
}
cd $dest
Write-Host "Done. Folder: $dest"
```

You should see four `Downloaded:` lines followed by `Done.`

3. Your PowerShell window is now inside the `erp-next` folder.
   Confirm by running `Get-Location` — the path shown should end with `erp-next`.

---

## 3. First-Time Setup

> **You must be in the `erp-next` folder** (step 2 above) before running this.
> If you opened a new PowerShell window, run this first to go back to the folder:
>
> ```powershell
> cd "$env:USERPROFILE\Documents\automation-scripts\erp-next"
> ```

Run the setup command:

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1
```

The script will ask you a series of questions. Here is what each one means:

| Prompt | What to enter | Example |
|---|---|---|
| `ERPNext base URL` | Your company's ERPNext web address | `https://erpnext.company.com` |
| `Login username` | Your ERPNext email | `john.doe@company.com` |
| `Password` | Your ERPNext password (hidden while typing) | *(type and press Enter)* |
| `Attendance Device ID` | Leave blank and press Enter to use default (`1`) | *(just press Enter)* |
| `Attendance API method` | Leave blank and press Enter to use default | *(just press Enter)* |
| `Log retention days` | How many days of history to keep — press Enter for 60 | *(just press Enter)* |
| `Scheduled check-in time` | Time to auto Check-IN — press Enter for `09:00` | `09:00` |
| `Scheduled check-out time` | Time to auto Check-OUT — press Enter for `18:00` | `18:00` |

After answering all prompts the script will:
1. Log in to ERPNext to verify your credentials
2. Find your Employee ID automatically
3. Log a Check-IN (or Check-OUT based on today's history)
4. Print `SUCCESS: Check-IN logged` in green

**If you see `SUCCESS` — the setup is working correctly.**

> Your password is encrypted using Windows security and stored on **this
> computer only**. No one else can read it, even if they copy the config file.

---

## 4. Set Up Automatic Scheduling

This step makes your PC check in automatically at startup and check out at your
configured time — completely hands-free.

> **This step requires running PowerShell as Administrator.**
>
> How to open PowerShell as Administrator:
> 1. Press the **Windows key**
> 2. Type `PowerShell`
> 3. Right-click **Windows PowerShell** in the results
> 4. Click **Run as administrator**
> 5. Click **Yes** on the User Account Control prompt

Once you have an **Administrator** PowerShell window, navigate to the folder:

```powershell
cd "$env:USERPROFILE\Documents\automation-scripts\erp-next"
```

Then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -AddScheduler
```

You should see output like:

```
  Registering ERPNext-Attendance-CheckIn (at logon) ...
  OK: ERPNext-Attendance-CheckIn
  Registering ERPNext-Attendance-CheckIn-Daily (daily 09:00) ...
  OK: ERPNext-Attendance-CheckIn-Daily
  Registering ERPNext-Attendance-CheckOut (daily 18:00) ...
  OK: ERPNext-Attendance-CheckOut

  Scheduled tasks registered.
  Check-IN  : at user logon  +  daily 09:00
  Check-OUT : daily 18:00
```

Three tasks are now registered:

| Task | When it runs | What it does |
|---|---|---|
| `ERPNext-Attendance-CheckIn` | Every time you log on to Windows | Logs Check-IN |
| `ERPNext-Attendance-CheckIn-Daily` | Daily at your check-in time | Backup Check-IN trigger |
| `ERPNext-Attendance-CheckOut` | Daily at your check-out time | Logs Check-OUT |

All three tasks skip weekends, holidays, and leave days automatically.

---

## 5. Confirm the Schedule in Task Scheduler

To visually confirm the tasks were created:

1. Press `Win + R`, type `taskschd.msc`, press Enter
2. Click **Task Scheduler Library** in the left panel
3. Look for the three `ERPNext-Attendance-*` entries

You should see something like this:

![Task Scheduler showing ERPNext-Attendance tasks registered and Ready](task_scheduler_screenshot.png)

Both tasks show **Status: Ready**, which means they will run at their next
scheduled trigger.

> **Next Run Time** shows when each task will next fire.
> If it says `30-11-1999` for Last Run Time that is normal — it means the task
> has not fired yet since it was just created.

---

## 6. Change Check-In / Check-Out Times

1. Open the file `erpnext-config.json` in Notepad:

```powershell
notepad erpnext-config.json
```

2. Find and update these two lines:

```json
"CheckInTime":  "09:00",
"CheckOutTime": "18:00"
```

Change `09:00` and `18:00` to your preferred times (24-hour format `HH:mm`).

3. Save and close Notepad (`Ctrl+S`, then close)

4. Re-register the scheduled tasks so the new times take effect
   (run PowerShell as Administrator — see step 4 above for how):

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -AddScheduler
```

---

## 7. Declare Public Holidays

Open `holidays.json` in Notepad:

```powershell
notepad holidays.json
```

Add or remove dates in `YYYY-MM-DD` format. Example:

```json
[
  "2026-01-01",
  "2026-01-26",
  "2026-08-15",
  "2026-10-02",
  "2026-12-25"
]
```

Rules:
- One date per line, wrapped in `"` quotes
- Separate dates with commas (except the last one)
- Dates must be in `YYYY-MM-DD` format (year-month-day)

The script will **not** log attendance on any date in this list.

---

## 8. Declare Personal Leave

Open `leaves.json` in Notepad:

```powershell
notepad leaves.json
```

Add dates when you are on leave in the same format as holidays:

```json
[
  "2026-06-10",
  "2026-06-11"
]
```

The script skips attendance on these dates.

> `leaves.json` is personal — it stays on your machine only and is not uploaded anywhere.

---

## 9. Working on a Weekend

By default the script skips Saturday and Sunday. If you need to work on a
specific weekend day, add that date to `working_weekend_dates.json`:

```powershell
notepad working_weekend_dates.json
```

```json
[
  "2026-04-06",
  "2026-04-11"
]
```

The script will run normally on those dates despite being a weekend.

To run the script immediately on a weekend (one-off manual override):

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -Force
```

---

## 10. Update ERPNext Credentials

If your ERPNext password changes or you need to point to a different server:

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -Reconfigure
```

The wizard will show your existing values in brackets — press Enter to keep
them, or type a new value to replace.

You do **not** need to re-run `-AddScheduler` after reconfiguring unless you
also changed the check-in/check-out times.

---

## 11. Remove the Scheduled Tasks

To completely remove all three scheduled tasks (run PowerShell as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -RemoveScheduler
```

Output:

```
  Removed: ERPNext-Attendance-CheckIn
  Removed: ERPNext-Attendance-CheckIn-Daily
  Removed: ERPNext-Attendance-CheckOut
  Scheduler cleanup complete.
```

---

## 12. Run Manually Any Time

You can always run the script manually from any PowerShell window:

```powershell
cd "$env:USERPROFILE\Documents\automation-scripts\erp-next"
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1
```

The script automatically decides:

| Today's log | Action taken |
|---|---|
| No attendance yet today | Check-IN |
| Last action was Check-IN | Check-OUT |
| Last action was Check-OUT | Check-IN (re-entry / overtime) |

---

## 13. Common Errors and Fixes

### "Access is denied" or tasks not created

**Cause:** You need Administrator rights to create scheduled tasks.

**Fix:** Close PowerShell, reopen it by right-clicking and choosing
**Run as administrator**, then run the `-AddScheduler` command again.

---

### "running scripts is disabled on this system"

**Cause:** PowerShell execution policy is blocking scripts.

**Fix:** Always run the script using this exact command (it bypasses the
policy for this run only, without permanently changing your system):

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1
```

---

### "Login failed" or "Server responded: 403"

**Cause:** Wrong username or password saved in the config.

**Fix:** Re-run setup to update your credentials:

```powershell
powershell -ExecutionPolicy Bypass -File .\ERPNext-Attendance.ps1 -Reconfigure
```

---

### "No Employee record found"

**Cause:** Your ERPNext user account does not have a linked Employee record,
or the `user_id` field in ERPNext does not match your login email.

**Fix:** Ask your ERPNext administrator to link your user account to an
Employee record in ERPNext (HR module > Employee > set User ID field).

---

### "The term 'powershell' is not recognized"

**Cause:** You are running the command inside a regular Command Prompt (cmd),
not PowerShell.

**Fix:** Open **Windows PowerShell** (not Command Prompt) and try again.

---

### Tasks show "Last Run Result: 0x41303" in Task Scheduler

**Cause:** The task has been registered but has not run yet (it is waiting for
the next trigger — logon or the scheduled time).

**Fix:** This is **normal**. The task will run automatically at the next
scheduled time or when you log off and back on.

---

### Script runs but nothing happens (no output)

**Cause:** The task runs hidden in the background when triggered by the
scheduler. There is no visible window.

**Fix:** Check `erpnext-attendance-log.json` to confirm entries were created:

```powershell
Get-Content erpnext-attendance-log.json | ConvertFrom-Json | Select-Object -Last 5 | Format-List
```

---

## File Reference

| File | Purpose | Downloaded from repo | Stays on your machine only |
|---|---|---|---|
| `ERPNext-Attendance.ps1` | Main script | Yes | - |
| `erpnext-config.json` | Your saved settings and encrypted password | No | Yes |
| `erpnext-attendance-log.json` | Full log of every request | No | Yes |
| `holidays.json` | Public holiday dates to skip | Yes | - |
| `leaves.json` | Your personal leave dates | Yes (empty) | Yes |
| `working_weekend_dates.json` | Weekend dates to work on | Yes | - |
| `ARGUMENTS.md` | Full CLI reference for advanced users | - | - |
