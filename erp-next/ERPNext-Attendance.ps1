#Requires -Version 5.1
<#
.SYNOPSIS
    ERPNext Attendance Automation - Auto Check In / Check Out v2.0

.DESCRIPTION
    Automatically logs attendance to ERPNext/Frappe.

    First run: prompts for connection settings and saves them to
    erpnext-config.json (password encrypted with Windows DPAPI -
    only decryptable by the same Windows user on the same machine).

    Subsequent runs: reads today's log to decide Check-IN or Check-OUT
    automatically. Skips weekends (unless in working_weekend_dates.json)
    and days listed in holidays.json or leaves.json.

    Every API call is appended to erpnext-attendance-log.json.
    Log entries older than LogRetentionDays (default 60) are pruned.

.PARAMETER Reconfigure
    Re-run the setup wizard to update saved connection settings.

.PARAMETER AddScheduler
    Register Windows Scheduled Tasks for automatic check-in/out:
      - Check-IN at user logon
      - Check-IN daily at CheckInTime (backup trigger)
      - Check-OUT daily at CheckOutTime
    Times are read from erpnext-config.json (default 09:00 / 18:00).

.PARAMETER RemoveScheduler
    Remove all Windows Scheduled Tasks registered by this script.

.PARAMETER Force
    Skip the holiday / weekend guard and run regardless of the day.

.NOTES
    Requires PowerShell 5.1+ on Windows.
    Run once without arguments to configure, then optionally use -AddScheduler.
#>

param(
    [switch] $Reconfigure,
    [switch] $AddScheduler,
    [switch] $RemoveScheduler,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  PATHS
# ---------------------------------------------------------------------------
$script:ScriptFile      = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:ConfigPath      = Join-Path $PSScriptRoot 'erpnext-config.json'
$script:LogPath         = Join-Path $PSScriptRoot 'erpnext-attendance-log.json'
$script:HolidayPath     = Join-Path $PSScriptRoot 'holidays.json'
$script:LeavePath       = Join-Path $PSScriptRoot 'leaves.json'
$script:WorkingWkndPath = Join-Path $PSScriptRoot 'working_weekend_dates.json'
$script:TaskNameIn      = 'ERPNext-Attendance-CheckIn'
$script:TaskNameInDaily = 'ERPNext-Attendance-CheckIn-Daily'
$script:TaskNameOut     = 'ERPNext-Attendance-CheckOut'

# ---------------------------------------------------------------------------
#  CONFIG
# ---------------------------------------------------------------------------

function Get-StoredConfig {
    if (-not (Test-Path $script:ConfigPath)) { return $null }
    $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json

    # Back-fill any fields added in v2.0 if the config was created by v1.0
    if ($null -eq $cfg.LogRetentionDays -or $cfg.LogRetentionDays -eq 0) {
        Add-Member -InputObject $cfg -MemberType NoteProperty -Name 'LogRetentionDays' -Value 60 -Force
    }
    if (-not $cfg.CheckInTime) {
        Add-Member -InputObject $cfg -MemberType NoteProperty -Name 'CheckInTime' -Value '09:00' -Force
    }
    if (-not $cfg.CheckOutTime) {
        Add-Member -InputObject $cfg -MemberType NoteProperty -Name 'CheckOutTime' -Value '18:00' -Force
    }
    return $cfg
}

function Save-ERPConfig {
    param(
        [string] $BaseUrl,
        [string] $Username,
        [string] $EncryptedPassword,
        [string] $AttendanceDeviceId,
        [string] $AttendanceEndpoint,
        [int]    $LogRetentionDays = 60,
        [string] $CheckInTime      = '09:00',
        [string] $CheckOutTime     = '18:00'
    )

    [ordered]@{
        BaseUrl            = $BaseUrl
        Username           = $Username
        EncryptedPassword  = $EncryptedPassword
        AttendanceDeviceId = $AttendanceDeviceId
        AttendanceEndpoint = $AttendanceEndpoint
        LogRetentionDays   = $LogRetentionDays
        CheckInTime        = $CheckInTime
        CheckOutTime       = $CheckOutTime
    } | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8

    Write-Host "  Config saved to: $script:ConfigPath" -ForegroundColor DarkGray
}

function Invoke-SetupWizard {
    param([object] $ExistingCfg = $null)

    Write-Host ''
    Write-Host '  +---------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  |      ERPNext - Setup / Reconfigure          |' -ForegroundColor Cyan
    Write-Host '  +---------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''

    $dUrl = if ($ExistingCfg -and $ExistingCfg.BaseUrl)            { $ExistingCfg.BaseUrl }            else { '' }
    $dUsr = if ($ExistingCfg -and $ExistingCfg.Username)           { $ExistingCfg.Username }           else { '' }
    $dDev = if ($ExistingCfg -and $ExistingCfg.AttendanceDeviceId) { $ExistingCfg.AttendanceDeviceId } else { '1' }
    $dEp  = if ($ExistingCfg -and $ExistingCfg.AttendanceEndpoint) { $ExistingCfg.AttendanceEndpoint } else { 'company.company_hr.api.log_attendance' }
    $dRet = if ($ExistingCfg -and $ExistingCfg.LogRetentionDays)   { $ExistingCfg.LogRetentionDays }   else { 60 }
    $dIn  = if ($ExistingCfg -and $ExistingCfg.CheckInTime)        { $ExistingCfg.CheckInTime }        else { '09:00' }
    $dOut = if ($ExistingCfg -and $ExistingCfg.CheckOutTime)       { $ExistingCfg.CheckOutTime }       else { '18:00' }

    $urlInput = (Read-Host "  ERPNext base URL  [$dUrl]").Trim()
    $baseUrl  = if ($urlInput) { $urlInput.TrimEnd('/') } else { $dUrl }
    if ($baseUrl -notmatch '^https?://') { throw "Invalid URL: must start with http:// or https://" }

    $usrInput = (Read-Host "  Login username  [$dUsr]").Trim()
    $username = if ($usrInput) { $usrInput } else { $dUsr }

    $secPass = Read-Host '  Password  (blank = keep existing)' -AsSecureString
    $bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
    $plain   = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $encPass = if ($plain.Length -gt 0) {
        ConvertFrom-SecureString $secPass
    } else {
        if ($ExistingCfg -and $ExistingCfg.EncryptedPassword) { $ExistingCfg.EncryptedPassword } else { '' }
    }

    $devInput = (Read-Host "  Attendance Device ID  [$dDev]").Trim()
    $deviceId = if ($devInput) { $devInput } else { $dDev }

    $epInput  = (Read-Host "  Attendance API method  [$dEp]").Trim()
    $endpoint = if ($epInput) { $epInput } else { $dEp }

    $retInput = (Read-Host "  Log retention days  [$dRet]").Trim()
    $retDays  = if ($retInput) { [int]$retInput } else { [int]$dRet }

    $inInput  = (Read-Host "  Scheduled check-in time HH:mm  [$dIn]").Trim()
    $inTime   = if ($inInput) { $inInput } else { $dIn }

    $outInput = (Read-Host "  Scheduled check-out time HH:mm  [$dOut]").Trim()
    $outTime  = if ($outInput) { $outInput } else { $dOut }

    Save-ERPConfig -BaseUrl $baseUrl -Username $username -EncryptedPassword $encPass `
                   -AttendanceDeviceId $deviceId -AttendanceEndpoint $endpoint `
                   -LogRetentionDays $retDays -CheckInTime $inTime -CheckOutTime $outTime

    return [PSCustomObject]@{
        BaseUrl            = $baseUrl
        Username           = $username
        EncryptedPassword  = $encPass
        AttendanceDeviceId = $deviceId
        AttendanceEndpoint = $endpoint
        LogRetentionDays   = $retDays
        CheckInTime        = $inTime
        CheckOutTime       = $outTime
    }
}

# ---------------------------------------------------------------------------
#  LOGGING
# ---------------------------------------------------------------------------

function Write-RequestLog {
    param(
        [string]    $Action,
        [string]    $Employee      = '',
        [string]    $Status,
        [string]    $Message       = '',
        [hashtable] $Payload       = @{},
        [int]       $RetentionDays = 60
    )

    $logs = @()
    if (Test-Path $script:LogPath) {
        $raw = Get-Content $script:LogPath -Raw | ConvertFrom-Json
        if ($null -ne $raw) { $logs = @($raw) }
    }

    # Prune entries older than RetentionDays
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $logs = @($logs | Where-Object {
        try   { [datetime]$_.Timestamp -gt $cutoff }
        catch { $true }
    })

    $logs += [ordered]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Action    = $Action
        Employee  = $Employee
        Status    = $Status
        Message   = $Message
        Payload   = $Payload
    }

    $logs | ConvertTo-Json -Depth 5 | Set-Content $script:LogPath -Encoding UTF8
}

function Get-TodayLastAttendanceAction {
    <# Returns 'IN', 'OUT', or $null based on last successful check today. #>
    if (-not (Test-Path $script:LogPath)) { return $null }
    $raw = Get-Content $script:LogPath -Raw | ConvertFrom-Json
    if ($null -eq $raw) { return $null }

    $today   = (Get-Date).ToString('yyyy-MM-dd')
    $entries = @($raw) | Where-Object {
        $_.Action -in @('CHECK_IN', 'CHECK_OUT') -and
        $_.Status -eq 'SUCCESS' -and
        $_.Timestamp -like "$today*"
    } | Sort-Object Timestamp

    if ($entries.Count -eq 0) { return $null }
    $last = $entries[$entries.Count - 1]
    if ($last.Action -eq 'CHECK_IN') { return 'IN' } else { return 'OUT' }
}

# ---------------------------------------------------------------------------
#  HOLIDAY / WEEKEND GUARD
# ---------------------------------------------------------------------------

function Test-ShouldSkipToday {
    param([switch] $Force)
    if ($Force) { return $false }

    $today    = Get-Date
    $todayStr = $today.ToString('yyyy-MM-dd')
    $dow      = [int]$today.DayOfWeek   # 0=Sunday  6=Saturday

    # Weekend guard
    if ($dow -eq 0 -or $dow -eq 6) {
        if (Test-Path $script:WorkingWkndPath) {
            $wknd = @(Get-Content $script:WorkingWkndPath -Raw | ConvertFrom-Json)
            if ($wknd -contains $todayStr) {
                Write-Host "  [INFO] Weekend override: $todayStr is a designated working day." -ForegroundColor Yellow
                return $false
            }
        }
        Write-Host "  [SKIP] $($today.DayOfWeek) is a weekend. No attendance logged." -ForegroundColor Yellow
        return $true
    }

    # Holiday guard
    if (Test-Path $script:HolidayPath) {
        $holidays = @(Get-Content $script:HolidayPath -Raw | ConvertFrom-Json)
        if ($holidays -contains $todayStr) {
            Write-Host "  [SKIP] $todayStr is a public holiday. No attendance logged." -ForegroundColor Yellow
            return $true
        }
    }

    # Leave guard
    if (Test-Path $script:LeavePath) {
        $leaves = @(Get-Content $script:LeavePath -Raw | ConvertFrom-Json)
        if ($leaves -contains $todayStr) {
            Write-Host "  [SKIP] $todayStr is marked as leave. No attendance logged." -ForegroundColor Yellow
            return $true
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
#  ERPNEXT / FRAPPE API
# ---------------------------------------------------------------------------

function Invoke-ERPNextLogin {
    param(
        [string]                       $BaseUrl,
        [string]                       $Username,
        [System.Security.SecureString] $SecurePassword
    )

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.UserAgent = 'ERPNext-Attendance-PS/1.0'

    $bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    try {
        $body = 'usr={0}&pwd={1}' -f [uri]::EscapeDataString($Username), [uri]::EscapeDataString($plainPwd)
        $resp = Invoke-WebRequest -UseBasicParsing `
            -Uri         "$BaseUrl/api/method/login" `
            -Method      POST `
            -WebSession  $session `
            -ContentType 'application/x-www-form-urlencoded' `
            -Headers     @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Accept' = 'application/json' } `
            -Body        $body
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $json = $resp.Content | ConvertFrom-Json
    if ($resp.StatusCode -ne 200 -or $json.message -ne 'Logged In') {
        throw "Login failed. Server responded: $($resp.Content)"
    }

    # Resolve CSRF token - strategy 1: cookie
    $csrfToken = $null
    foreach ($cookie in $session.Cookies.GetCookies($BaseUrl)) {
        if ($cookie.Name -eq 'csrf_token') { $csrfToken = $cookie.Value; break }
    }

    # Strategy 2: dedicated endpoint (Frappe v14+)
    if (-not $csrfToken) {
        try {
            $cr = Invoke-RestMethod -UseBasicParsing `
                -Uri        "$BaseUrl/api/method/frappe.csrf_token" `
                -WebSession $session `
                -Headers    @{ 'X-Requested-With' = 'XMLHttpRequest' }
            $csrfToken = $cr.message
        }
        catch {
            Write-Warning 'CSRF token endpoint unavailable - POST calls may fail.'
        }
    }

    return @{ Session = $session; CsrfToken = $csrfToken }
}

function Get-EmployeeId {
    param(
        [string] $BaseUrl,
        $Session,
        [string] $Username
    )

    $filters = ConvertTo-Json @(, @('user_id', '=', $Username)) -Compress
    $fields  = '["name","employee_name"]'
    $url     = '{0}/api/resource/Employee?filters={1}&fields={2}' -f $BaseUrl, [uri]::EscapeDataString($filters), [uri]::EscapeDataString($fields)

    $resp = Invoke-RestMethod -UseBasicParsing `
        -Uri        $url `
        -WebSession $Session `
        -Headers    @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Accept' = 'application/json' }

    if (-not $resp.data -or $resp.data.Count -eq 0) {
        throw "No Employee record found for user '$Username'. Check the user_id field in ERPNext."
    }

    return $resp.data[0].name
}

function Invoke-AttendanceLog {
    param(
        [string] $BaseUrl,
        $Session,
        [string] $CsrfToken,
        [string] $EmployeeId,
        [string] $DeviceId,
        [string] $Endpoint,
        [ValidateSet('IN', 'OUT')]
        [string] $LogType
    )

    $headers = [ordered]@{
        'X-Requested-With' = 'XMLHttpRequest'
        'Accept'           = 'application/json'
    }
    if ($CsrfToken) { $headers['X-Frappe-CSRF-Token'] = $CsrfToken }

    $body = 'employee={0}&attendance_device_id={1}&log_type={2}' -f `
        [uri]::EscapeDataString($EmployeeId), [uri]::EscapeDataString($DeviceId), $LogType

    $resp = Invoke-WebRequest -UseBasicParsing `
        -Uri         "$BaseUrl/api/method/$Endpoint" `
        -Method      POST `
        -WebSession  $Session `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -Headers     $headers `
        -Body        $body

    return $resp.Content | ConvertFrom-Json
}

function Get-ServerMessage {
    param($Result)
    if ($Result._server_messages) {
        try {
            $msgs = $Result._server_messages | ConvertFrom-Json
            return ($msgs | ForEach-Object { ($_ | ConvertFrom-Json).message }) -join ' | '
        }
        catch { return $Result._server_messages }
    }
    if ($Result.message) { return $Result.message }
    return ''
}

# ---------------------------------------------------------------------------
#  WINDOWS TASK SCHEDULER
# ---------------------------------------------------------------------------

function Add-ScheduledTasks {
    param([object] $Cfg)

    $scriptPath = $script:ScriptFile
    $inTime     = if ($Cfg.CheckInTime)  { $Cfg.CheckInTime }  else { '09:00' }
    $outTime    = if ($Cfg.CheckOutTime) { $Cfg.CheckOutTime } else { '18:00' }

    $psArg = '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "' + $scriptPath + '"'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArg

    # Task 1: Check-IN at user logon
    Write-Host "  Registering $script:TaskNameIn (at logon) ..." -ForegroundColor Yellow
    try {
        Register-ScheduledTask -TaskName $script:TaskNameIn `
            -Action  $action `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
            -RunLevel Limited -Force | Out-Null
        Write-Host "  OK: $script:TaskNameIn" -ForegroundColor Green
    }
    catch { Write-Warning "  Failed to register $script:TaskNameIn : $_" }

    # Task 2: Check-IN daily backup
    Write-Host "  Registering $script:TaskNameInDaily (daily $inTime) ..." -ForegroundColor Yellow
    try {
        Register-ScheduledTask -TaskName $script:TaskNameInDaily `
            -Action  $action `
            -Trigger (New-ScheduledTaskTrigger -Daily -At $inTime) `
            -RunLevel Limited -Force | Out-Null
        Write-Host "  OK: $script:TaskNameInDaily" -ForegroundColor Green
    }
    catch { Write-Warning "  Failed to register $script:TaskNameInDaily : $_" }

    # Task 3: Check-OUT daily
    Write-Host "  Registering $script:TaskNameOut (daily $outTime) ..." -ForegroundColor Yellow
    try {
        Register-ScheduledTask -TaskName $script:TaskNameOut `
            -Action  $action `
            -Trigger (New-ScheduledTaskTrigger -Daily -At $outTime) `
            -RunLevel Limited -Force | Out-Null
        Write-Host "  OK: $script:TaskNameOut" -ForegroundColor Green
    }
    catch { Write-Warning "  Failed to register $script:TaskNameOut : $_" }

    Write-Host ''
    Write-Host '  Scheduled tasks registered.' -ForegroundColor Green
    Write-Host "  Check-IN  : at user logon  +  daily $inTime"
    Write-Host "  Check-OUT : daily $outTime"
    Write-Host '  To update times: edit CheckInTime/CheckOutTime in erpnext-config.json'
    Write-Host '  then re-run:  .\ERPNext-Attendance.ps1 -AddScheduler'
}

function Remove-ScheduledTasks {
    $names = @($script:TaskNameIn, $script:TaskNameInDaily, $script:TaskNameOut)
    foreach ($name in $names) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "  Removed: $name" -ForegroundColor Green
        }
        else {
            Write-Host "  Not found (skipped): $name" -ForegroundColor DarkGray
        }
    }
    Write-Host '  Scheduler cleanup complete.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------

function Main {
    param(
        [switch] $Reconfigure,
        [switch] $AddScheduler,
        [switch] $RemoveScheduler,
        [switch] $Force
    )

    Write-Host ''
    Write-Host '  +============================================+' -ForegroundColor Cyan
    Write-Host '  |    ERPNext Attendance Automation  v2.0     |' -ForegroundColor Cyan
    Write-Host '  +============================================+' -ForegroundColor Cyan

    # -- Scheduler-only CLI actions (no login needed) ------------------------------
    if ($RemoveScheduler) {
        Write-Host "`n  Removing scheduled tasks ..." -ForegroundColor Yellow
        Remove-ScheduledTasks
        return
    }

    if ($AddScheduler) {
        $cfg = Get-StoredConfig
        if (-not $cfg -or -not $cfg.BaseUrl) {
            Write-Host '  ERROR: No config found. Run without arguments first to configure.' -ForegroundColor Red
            return
        }
        Write-Host "`n  Adding scheduled tasks ..." -ForegroundColor Yellow
        Add-ScheduledTasks -Cfg $cfg
        return
    }

    # -- Step 0: Load / create config ----------------------------------------------
    $cfg = Get-StoredConfig
    if (-not $cfg -or -not $cfg.BaseUrl -or $Reconfigure) {
        $label = if ($Reconfigure -and $cfg) { 'Reconfigure flag set.' } else { 'No config found.' }
        Write-Host "`n  $label Running setup wizard ..." -ForegroundColor Yellow
        $cfg = Invoke-SetupWizard -ExistingCfg $cfg
    }
    else {
        Write-Host "`n  Config: [$($cfg.Username)] @ [$($cfg.BaseUrl)]" -ForegroundColor DarkGray
        Write-Host '  Use -Reconfigure to change settings.' -ForegroundColor DarkGray
    }

    $retDays = if ($cfg.LogRetentionDays) { [int]$cfg.LogRetentionDays } else { 60 }

    # -- Step 0b: Holiday / weekend guard ------------------------------------------
    if (Test-ShouldSkipToday -Force:$Force) { return }

    # -- Step 0c: Decide IN or OUT from today log ----------------------------------
    $lastAction = Get-TodayLastAttendanceAction
    if ($lastAction -eq 'IN') {
        $logType = 'OUT'
        Write-Host '  [AUTO] Last action today: Check-IN  ->  will Check-OUT' -ForegroundColor Cyan
    }
    elseif ($lastAction -eq 'OUT') {
        $logType = 'IN'
        Write-Host '  [AUTO] Last action today: Check-OUT ->  will Check-IN (re-entry / overtime)' -ForegroundColor Cyan
    }
    else {
        $logType = 'IN'
        Write-Host '  [AUTO] No attendance logged today   ->  will Check-IN' -ForegroundColor Cyan
    }

    # -- Step 1: Login -------------------------------------------------------------
    Write-Host ''
    Write-Host '  [1/3] Logging in ...' -ForegroundColor Yellow
    try {
        $secPass = ConvertTo-SecureString $cfg.EncryptedPassword
        $auth    = Invoke-ERPNextLogin -BaseUrl $cfg.BaseUrl -Username $cfg.Username -SecurePassword $secPass
        Write-Host "        OK - authenticated as $($cfg.Username)" -ForegroundColor Green
        Write-RequestLog -Action 'LOGIN' -Status 'SUCCESS' `
            -Message "Authenticated as $($cfg.Username)" -RetentionDays $retDays
    }
    catch {
        Write-Host "        FAILED: $_" -ForegroundColor Red
        Write-RequestLog -Action 'LOGIN' -Status 'FAILED' -Message $_.ToString() -RetentionDays $retDays
        return
    }

    # -- Step 2: Resolve Employee ID -----------------------------------------------
    Write-Host '  [2/3] Fetching employee record ...' -ForegroundColor Yellow
    try {
        $empId = Get-EmployeeId -BaseUrl $cfg.BaseUrl -Session $auth.Session -Username $cfg.Username
        Write-Host "        Employee ID: $empId" -ForegroundColor Green
        Write-RequestLog -Action 'GET_EMPLOYEE' -Employee $empId -Status 'SUCCESS' `
            -Message 'Employee ID resolved' -RetentionDays $retDays
    }
    catch {
        Write-Host "        FAILED: $_" -ForegroundColor Red
        Write-RequestLog -Action 'GET_EMPLOYEE' -Status 'FAILED' -Message $_.ToString() -RetentionDays $retDays
        return
    }

    # -- Step 3: Post attendance ---------------------------------------------------
    Write-Host "  [3/3] Check-$logType for [$empId] ..." -ForegroundColor Yellow

    $payload = @{
        employee             = $empId
        attendance_device_id = $cfg.AttendanceDeviceId
        log_type             = $logType
    }

    try {
        $result = Invoke-AttendanceLog `
            -BaseUrl    $cfg.BaseUrl `
            -Session    $auth.Session `
            -CsrfToken  $auth.CsrfToken `
            -EmployeeId $empId `
            -DeviceId   $cfg.AttendanceDeviceId `
            -Endpoint   $cfg.AttendanceEndpoint `
            -LogType    $logType

        $msg = Get-ServerMessage -Result $result
        Write-Host "        SUCCESS: $msg" -ForegroundColor Green
        Write-RequestLog -Action "CHECK_$logType" -Employee $empId -Status 'SUCCESS' `
            -Message $msg -Payload $payload -RetentionDays $retDays
    }
    catch {
        Write-Host "        FAILED: $_" -ForegroundColor Red
        Write-RequestLog -Action "CHECK_$logType" -Employee $empId -Status 'FAILED' `
            -Message $_.ToString() -Payload $payload -RetentionDays $retDays
    }

    Write-Host ''
}

Main -Reconfigure:$Reconfigure -AddScheduler:$AddScheduler -RemoveScheduler:$RemoveScheduler -Force:$Force
