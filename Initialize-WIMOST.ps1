#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the WIMOST folder structure and downloads the latest Cumulative Update (including
    checkpoint CUs) and .NET Framework update from the Microsoft Update Catalog.

.DESCRIPTION
    Part of the WIM Offline Servicing Toolkit (WIMOST). Run this script before Build-MasterImage.ps1.

    - Creates the WIMOST working directory structure on the given drive.
    - Searches the Microsoft Update Catalog for the latest x64 Cumulative Update (LCU) and the latest
      .NET Framework Cumulative Update for the selected Windows 11 release. Previews, Insider builds,
      Server and Dynamic Updates are excluded.
    - If the LCU download contains checkpoint cumulative updates (prerequisites of the LCU), they are
      separated from the main update and stored in the CCU folder.
    - The previous-month fallback is only used when the Catalog returns nothing suitable. It is not
      used for network or download errors, so an older update is never downloaded silently.
    - Downloads are written to a .part file and renamed after completion, so an interrupted download
      is never mistaken for a finished one on the next run.
    - Web requests are retried (3 attempts).
    - Older files in the target folders are removed after a successful download.
    - Writes a transcript to <MainDrive>\WIMOST\Logs\InitializeWIMOST_<OSMain>_<timestamp>.log and
      prints a summary of the provided files at the end. Exit code 1 if any step failed.

    Language packs, Features on Demand, the Windows ISO, cmtrace.exe and the SXS sources are NOT
    downloaded. The script only creates the folders for them (see README.md).

.PARAMETER MainDrive
    Drive on which the WIMOST structure is created. Default: G:

.PARAMETER OSMain
    OS release name used for the folder structure and as the default Catalog search term (e.g. 26H2).

.PARAMETER CatalogOSName
    Name used in the Catalog search term. Default: the value of OSMain.
    Override it if the Catalog lists the updates under a different name (e.g. "Version 24H2").

.PARAMETER CheckpointDir
    Target folder for checkpoint cumulative updates (prerequisites of the LCU).
    Default: <MainDrive>\WIMOST\CCU\<OSMain>
    Assignment: the file whose name contains the KB number from the title of the main update goes to
    LCU, all other files of the download go to CCU.

.PARAMETER LcuQueryTemplate
    Search term template for the LCU. {0} = yyyy-MM, {1} = CatalogOSName.

.PARAMETER DotNetQueryTemplate
    Search term template for the .NET update. {0} = yyyy-MM, {1} = CatalogOSName.

.EXAMPLE
    .\Initialize-WIMOST.ps1 -MainDrive D: -OSMain 26H2

    Creates D:\WIMOST\... and downloads the latest LCU, checkpoint CU and .NET update for 26H2.

.NOTES
    Version : 1.0.0
    License : MIT
    The Microsoft Update Catalog has no official API. This script parses the public web pages and
    may stop working if Microsoft changes them.
#>
[CmdletBinding()]
param(
    [string]$MainDrive = "C:",
    [string]$OSMain    = "26H2",
    [string]$CatalogOSName,
    [string]$CheckpointDir,
    [string]$LcuQueryTemplate    = "{0} Cumulative Update for Windows 11 {1}",
    [string]$DotNetQueryTemplate = "{0} Cumulative Update for .NET Framework Windows 11 {1}"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # greatly speeds up Invoke-WebRequest -OutFile in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $CatalogOSName) { $CatalogOSName = $OSMain }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$WimostRoot     = Join-Path $MainDrive  'WIMOST'
$MountPath      = Join-Path $WimostRoot 'MOUNT'
$LogRoot        = Join-Path $WimostRoot 'Logs'
$IsoDir         = Join-Path $WimostRoot "ISO\$OSMain"
$DotNetDir      = Join-Path $WimostRoot "DOTNET\$OSMain"
$LcuDir         = Join-Path $WimostRoot "LCU\$OSMain"
$CcuDir         = if ($CheckpointDir) { $CheckpointDir } else { Join-Path $WimostRoot "CCU\$OSMain" }
$LangDir        = Join-Path $WimostRoot "LANGUAGES\$OSMain"
$LangFeatureDir = Join-Path $WimostRoot "LANG_FEATURES\$OSMain"
$FoDDir         = Join-Path $WimostRoot "FODS\$OSMain"
$FoDMetaDir     = Join-Path $FoDDir     "metadata"
$LangMetaDir    = Join-Path $LangFeatureDir "metadata"
$ToolsDir       = Join-Path $WimostRoot "Tools"
$SxsDir         = Join-Path $ToolsDir   "sources\sxs"
$CatalogHeaders = @{
    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Accept-Language" = "en-US,en;q=0.9"
}

# Collections for failures and provided files (summary at the end)
$Failures = New-Object System.Collections.Generic.List[string]
$Summary  = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

# Invoke-WebRequest with retries. Parameters are passed as a hashtable (splatting).
function Invoke-WebRequestRetry {
    param(
        [Parameter(Mandatory)][hashtable]$Params,
        [int]$MaxRetries   = 3,
        [int]$DelaySeconds = 5
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            return Invoke-WebRequest @Params
        }
        catch {
            if ($i -ge $MaxRetries) { throw }
            Write-Log "Web request failed (attempt $i of $MaxRetries): $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# ---------------------------------------------------------------------------
# Targeted search in the Microsoft Update Catalog (with browser headers)
# Returns: 'OK' | 'NotFound' (Catalog returned nothing suitable) | 'Error' (technical error)
# ---------------------------------------------------------------------------
function Get-LatestUpdateFromCatalog {
    param(
        [Parameter(Mandatory)][string]$SearchQuery,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$RequiredKeyword,   # regex, must appear in the title
        [string]$ExcludeKeyword,                          # regex, must NOT appear in the title
        [string]$CheckpointFolder,                        # optional: target folder for checkpoint updates
        [string]$Label = 'Update'
    )

    Write-Log "Searching Microsoft Update Catalog for: '$SearchQuery'..."
    $CatalogUri = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([Uri]::EscapeDataString($SearchQuery))"
    $Invariant  = [System.Globalization.CultureInfo]::InvariantCulture

    try {
        $WebResponse = Invoke-WebRequestRetry -Params @{ Uri = $CatalogUri; Headers = $CatalogHeaders; UseBasicParsing = $true }
        $Html = $WebResponse.Content

        # Parse row by row: <tr id='GUID_R0'> ... </tr>
        $Rows = [regex]::Matches($Html, '(?s)<tr[^>]*id=["'']([0-9a-fA-F\-]{36})_R\d+["''][^>]*>(.*?)</tr>')

        $Candidates = foreach ($row in $Rows) {
            $UpdateId = $row.Groups[1].Value
            $RowHtml  = $row.Groups[2].Value

            $tm = [regex]::Match($RowHtml, '(?s)<a[^>]*id=["'']' + [regex]::Escape($UpdateId) + '_link["''][^>]*>\s*(.*?)\s*</a>')
            $dm = [regex]::Match($RowHtml, '(\d{1,2}/\d{1,2}/\d{4})')
            if (-not $tm.Success -or -not $dm.Success) { continue }

            $Title = ($tm.Groups[1].Value -replace '<[^>]+>', '').Trim()
            $Date  = [datetime]::ParseExact($dm.Groups[1].Value, 'M/d/yyyy', $Invariant)

            # Filter: x64, required keyword, NO previews, Insider, Server or Dynamic Updates
            if ($Title -match 'x64' -and
                $Title -match $RequiredKeyword -and
                $Title -notmatch 'Preview|Beta|Server|Dynamic' -and
                (-not $ExcludeKeyword -or $Title -notmatch $ExcludeKeyword)) {

                [PSCustomObject]@{ UpdateId = $UpdateId; Title = $Title; LastUpdated = $Date }
            }
        }

        if (-not $Candidates) {
            Write-Log "No matching updates found in the Catalog for '$SearchQuery' (rows in HTML: $($Rows.Count))." 'WARN'
            return 'NotFound'
        }

        # Pick the newest update
        $Latest = $Candidates | Sort-Object LastUpdated -Descending | Select-Object -First 1
        Write-Log "Found: $($Latest.Title) (date: $($Latest.LastUpdated.ToString('yyyy-MM-dd')))"

        # Get download URL(s) via DownloadDialog
        $PostObj = @{ size = 0; UpdateID = $Latest.UpdateId; UidInfo = $Latest.UpdateId }
        $Body    = @{ UpdateIDs = "[$($PostObj | ConvertTo-Json -Compress)]" }
        $DownloadPage = Invoke-WebRequestRetry -Params @{
            Uri             = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
            Method          = 'Post'
            Body            = $Body
            Headers         = $CatalogHeaders
            UseBasicParsing = $true
        }

        $Urls = @([regex]::Matches($DownloadPage.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -match '\.(msu|cab)$' } |
                Select-Object -Unique)

        if ($Urls.Count -eq 0) {
            Write-Log "No download URL found in the DownloadDialog." 'ERROR'
            return 'Error'
        }

        # KB number of the main update from the title (e.g. KB5134133)
        $MainKb = [regex]::Match($Latest.Title, 'KB\d+').Value

        # Check whether the main update can be identified unambiguously in the download.
        # If not, files are NOT separated (everything goes to $TargetFolder).
        $SplitActive = $false
        if ($CheckpointFolder -and $MainKb) {
            $MainFileFound = $Urls | Where-Object { (($_ -split '/')[-1]) -match [regex]::Escape($MainKb) }
            if ($MainFileFound) { $SplitActive = $true }
            else { Write-Log "Main update $MainKb is not clearly identifiable in the download - no separation into CCU." 'WARN' }
        }

        # Download plan: URL, file name, target folder
        $Plan = @(foreach ($FileUrl in $Urls) {
            $FileName = ($FileUrl -split '/')[-1]
            $Dest     = $TargetFolder
            if ($SplitActive -and $FileName -notmatch [regex]::Escape($MainKb)) { $Dest = $CheckpointFolder }
            [PSCustomObject]@{ Url = $FileUrl; Name = $FileName; Dest = $Dest }
        })

        foreach ($item in $Plan) {
            if (-not (Test-Path $item.Dest)) { New-Item -ItemType Directory -Path $item.Dest -Force | Out-Null }
            $TargetPath = Join-Path $item.Dest $item.Name
            $StepName   = if ($SplitActive -and $item.Dest -eq $CheckpointFolder) { 'Checkpoint CU' } else { $Label }

            if (Test-Path $TargetPath) {
                Write-Log "Package already present locally: $($item.Name)" 'WARN'
                $State = 'present'
            }
            else {
                # Download to .part first, then rename: an interrupted download is never treated as complete
                $PartPath = "$TargetPath.part"
                Write-Log "Downloading package: $($item.Name) -> $($item.Dest)..."
                Invoke-WebRequestRetry -Params @{ Uri = $item.Url; OutFile = $PartPath; UseBasicParsing = $true } | Out-Null
                if (-not (Test-Path $PartPath) -or (Get-Item $PartPath).Length -eq 0) {
                    throw "Download of '$($item.Name)' resulted in a missing or empty file."
                }
                Move-Item -Path $PartPath -Destination $TargetPath -Force
                Write-Log "Download successful: $($item.Name)"
                $State = 'downloaded'
            }
            $Summary.Add([PSCustomObject]@{ Step = $StepName; File = $item.Name; State = $State; Folder = $item.Dest })
        }

        # Remove older files only AFTER a successful download (per target folder).
        # If separation is active, CCU is cleaned as well - if the LCU no longer ships a checkpoint,
        # CCU is emptied so no outdated checkpoint CU is left behind.
        $Folders = @($TargetFolder)
        if ($SplitActive) { $Folders += $CheckpointFolder }

        foreach ($Folder in ($Folders | Select-Object -Unique)) {
            if (-not (Test-Path $Folder)) { continue }
            $KeepNames = @($Plan | Where-Object { $_.Dest -eq $Folder } | ForEach-Object { $_.Name })
            Get-ChildItem -Path $Folder -File |
                Where-Object { $_.Name -notin $KeepNames } |
                ForEach-Object {
                    Write-Log "Removing outdated file: $($_.Name) ($Folder)"
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                }
        }

        return 'OK'
    }
    catch {
        Write-Log "Error during Catalog request: $_" 'ERROR'
    }
    return 'Error'
}

# ---------------------------------------------------------------------------
# Wrapper with automatic fallback to the previous month (only if the Catalog finds nothing)
# Returns: $true / $false
# ---------------------------------------------------------------------------
function Invoke-UpdateDownloadWithFallback {
    param(
        [Parameter(Mandatory)][string]$QueryTemplate,     # {0} = yyyy-MM, {1} = OS name
        [Parameter(Mandatory)][string]$OSName,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$RequiredKeyword,
        [string]$ExcludeKeyword,
        [string]$CheckpointFolder,
        [string]$Label = 'Update'
    )

    $TryDates = @(
        (Get-Date),                    # attempt 1: current month
        (Get-Date).AddMonths(-1)       # attempt 2: previous month (fallback)
    )

    for ($n = 0; $n -lt $TryDates.Count; $n++) {
        $ym    = $TryDates[$n].ToString("yyyy-MM", [System.Globalization.CultureInfo]::InvariantCulture)
        $query = $QueryTemplate -f $ym, $OSName

        $status = @(Get-LatestUpdateFromCatalog -SearchQuery $query -TargetFolder $TargetFolder `
                       -RequiredKeyword $RequiredKeyword -ExcludeKeyword $ExcludeKeyword `
                       -CheckpointFolder $CheckpointFolder -Label $Label)[-1]

        if ($status -eq 'OK')    { return $true }
        if ($status -eq 'Error') { return $false }   # technical error: no fallback to an older update

        if ($n -lt ($TryDates.Count - 1)) {
            Write-Log "No results for $ym. Trying fallback to the previous month..." 'WARN'
        }
    }
    Write-Log "Could not determine a $Label from the Catalog, even with fallback." 'ERROR'
    return $false
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$LogFile = Join-Path $LogRoot ("InitializeWIMOST_{0}_{1}.log" -f $OSMain, (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    Write-Log "Start: initializing the WIMOST environment on drive $MainDrive (OS $OSMain)"

    $Directories = @(
        $WimostRoot, $MountPath, $LogRoot, $IsoDir, $DotNetDir,
        $LcuDir, $CcuDir, $LangDir, $LangFeatureDir, $LangMetaDir,
        $FoDDir, $FoDMetaDir, $ToolsDir, $SxsDir
    )

    foreach ($dir in $Directories) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Log "Directory created: $dir"
        }
    }

    # 1. Get the LCU (without .NET updates) with fallback; checkpoint CUs go to CCU
    $ok = @(Invoke-UpdateDownloadWithFallback -QueryTemplate $LcuQueryTemplate -OSName $CatalogOSName `
                -TargetFolder $LcuDir -RequiredKeyword 'Cumulative Update' -ExcludeKeyword '\.NET' `
                -CheckpointFolder $CcuDir -Label 'LCU')[-1]
    if (-not $ok) { $Failures.Add('LCU') }

    # 2. Get the .NET update with fallback
    $ok = @(Invoke-UpdateDownloadWithFallback -QueryTemplate $DotNetQueryTemplate -OSName $CatalogOSName `
                -TargetFolder $DotNetDir -RequiredKeyword '\.NET' -Label '.NET')[-1]
    if (-not $ok) { $Failures.Add('.NET') }

    # Summary
    Write-Log "Summary:"
    if ($Summary.Count -eq 0) {
        Write-Log "  No update files provided." 'WARN'
    }
    foreach ($s in $Summary) {
        Write-Log ("  {0,-14} {1} [{2}]" -f $s.Step, $s.File, $s.State)
    }
    Write-Log "ISO folder:     $IsoDir"
    Write-Log "LCU:            $LcuDir"
    Write-Log "Checkpoint CU:  $CcuDir"
    Write-Log "Log file:       $LogFile"

    if ($Failures.Count -gt 0) {
        Write-Log ("Initialization finished with errors: {0}" -f ($Failures -join ', ')) 'ERROR'
    }
    else {
        Write-Log "Initialization and automatic update provisioning completed."
    }
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) 'ERROR'
    $Failures.Add('Unhandled error')
}
finally {
    Stop-Transcript | Out-Null
}

if ($Failures.Count -gt 0) { exit 1 }
