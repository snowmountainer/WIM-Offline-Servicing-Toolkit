#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a Windows 11 master WIM by offline servicing of the install.wim from an ISO: checkpoint CU,
    LCU, .NET, language packs, language features, FoDs, Defender signatures, CMTrace, SXS sources and
    AppX cleanup.

.DESCRIPTION
    Part of the WIM Offline Servicing Toolkit (WIMOST). Run Initialize-WIMOST.ps1 first.

    - The source is always the install.wim of the newest ISO in WIMOST\ISO\<OSMain>
      (fallback: WIMOST\ISO).
    - The working copy of the install.wim is mounted and serviced offline in this order:
      checkpoint CU(s) from WIMOST\CCU\<OSMain>, LCU, .NET update, language packs, language features
      and Features on Demand.
    - The latest Microsoft Defender antimalware signatures are downloaded (Authenticode signature is
      verified) and integrated into the image.
    - cmtrace.exe (WIMOST\Tools) and the FoD SXS sources (WIMOST\Tools\sources\sxs) are copied into
      the image if present.
    - An intermediate commit flushes pending package transactions. The image is then remounted, and
      provisioned AppX packages that are not on the built-in allow list are removed.
    - The target build is determined after the package installation: the OS build number comes from
      CurrentBuildNumber in the registry of the mounted image, the revision from the highest
      Package_for_RollupFix. (The build part of the RollupFix package name is the servicing branch,
      e.g. 26100, and not the OS build number, e.g. 26300.)
    - The finished WIM is exported with maximum compression and named <OS build>.<revision>.wim
      (for example 26300.9725.wim).
    - Writes a transcript to <MainDrive>\WIMOST\Logs\BuildMasterImage_<OSMain>_<timestamp>.log and the
      list of installed packages to <MainDrive>\WIMOST\Packages.txt. Exit code 1 on failure.

.PARAMETER MainDrive
    Drive that holds the WIMOST structure. Default: G:

.PARAMETER OSMain
    OS release name used for the folder structure (e.g. 26H2). Must match the value used with
    Initialize-WIMOST.ps1.

.PARAMETER ImageIndex
    Index of the edition inside the ISO's install.wim that is serviced and exported. The index depends
    on the ISO. List the available editions with:
    Get-WindowsImage -ImagePath <path to install.wim>
    Default: 3

.PARAMETER ImagesPath
    Folder for the temporary working WIM and the finished WIM.
    Default: <MainDrive>\WIMOST\Images
    A local path is recommended, because the working copy is mounted from this folder.

.PARAMETER KeepTemp
    Keep the temporary working WIM (Temp_<OSMain>.wim) after a successful run.

.EXAMPLE
    .\Build-MasterImage.ps1 -MainDrive D: -OSMain 26H2 -ImageIndex 6

    Builds the master WIM from the newest ISO in D:\WIMOST\ISO\26H2, using edition index 6.

.EXAMPLE
    .\Build-MasterImage.ps1 -MainDrive D: -ImagesPath E:\Images -KeepTemp

    Writes the working and finished WIM to E:\Images and keeps the temporary WIM.

.NOTES
    Version : 1.0.0
    License : MIT
    Review the AppX allow list ($WhitelistedApps) before use. Every provisioned AppX package that is
    not on the list is removed from the image.
#>
[CmdletBinding()]
param(
    [string]$MainDrive  = "C:",
    [string]$OSMain     = "26H2",
    [int]   $ImageIndex = 3,
    [string]$ImagesPath,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$WimostRoot     = Join-Path $MainDrive  'WIMOST'
$MountPath      = Join-Path $WimostRoot 'MOUNT'
$LogRoot        = Join-Path $WimostRoot 'Logs'
$IsoDir         = Join-Path $WimostRoot 'ISO'
$IsoOsDir       = Join-Path $IsoDir     $OSMain

$DotNetDir      = Join-Path $WimostRoot "DOTNET\$OSMain"
$CcuDir         = Join-Path $WimostRoot "CCU\$OSMain"
$LcuDir         = Join-Path $WimostRoot "LCU\$OSMain"
$LangDir        = Join-Path $WimostRoot "LANGUAGES\$OSMain"
$LangFeatureDir = Join-Path $WimostRoot "LANG_FEATURES\$OSMain"
$FoDDir         = Join-Path $WimostRoot "FODS\$OSMain"
$ToolsDir       = Join-Path $WimostRoot "Tools"

$CMTraceSource  = Join-Path $ToolsDir 'cmtrace.exe'
$SxsSourceDir   = Join-Path $ToolsDir 'sources\sxs'
$TargetSxsDir   = Join-Path $MountPath 'Windows\sources\sxs'

$DefenderUrl     = "https://go.microsoft.com/fwlink/?LinkID=121721&arch=x64"
$DefenderRoot    = Join-Path $WimostRoot 'MDATP'
$DefenderExe     = Join-Path $DefenderRoot 'mpam-fe-x64.exe'
$DefenderExtract = Join-Path $DefenderRoot 'Extracted'
$DefenderTarget  = Join-Path $MountPath 'ProgramData\Microsoft\Windows Defender\Definition Updates\Updates'

# The target build is only known after the LCU installation. Until then the script works with
# neutral temp names; the finished WIM is then named <target build>.wim.
$ImagesDir = if ($ImagesPath) { $ImagesPath } else { Join-Path $WimostRoot 'Images' }
$TempWIM   = Join-Path $ImagesDir "Temp_$OSMain.wim"
$NewWIM    = Join-Path $ImagesDir "Temp_$OSMain.new.wim"

$PackageListFile = Join-Path $WimostRoot 'Packages.txt'

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

function Invoke-Dism {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Step
    )
    Write-Log "DISM: $Step"
    & dism.exe @Arguments | Out-Host
    if ($LASTEXITCODE -notin 0, 3010) {
        throw "DISM step '$Step' failed (exit code $LASTEXITCODE)."
    }
}

function Add-OfflinePackages {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Label,
        [switch]$ContinueOnError   # treat per-file errors as warnings only (e.g. checkpoint CU)
    )
    if (-not $Files) {
        Write-Log "No files found for '$Label' - skipped." 'WARN'
        return
    }
    foreach ($f in ($Files | Sort-Object Name)) {
        Write-Log "Installing ${Label}: $($f.Name)"
        try {
            Add-WindowsPackage -PackagePath $f.FullName -Path $MountPath -LogLevel Debug | Out-Null
            Write-Log "Installed ${Label}: $($f.Name)"
        }
        catch {
            if ($ContinueOnError) {
                Write-Log "${Label} '$($f.Name)' could not be installed (possibly already part of the base image): $($_.Exception.Message)" 'WARN'
            }
            else { throw }
        }
    }
}

# Determines the highest Package_for_RollupFix (servicing branch build + revision) from a package listing.
# Naming scheme: Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.9725.1.14
# NOTE: The build part is the servicing branch (e.g. 26100, shared by 24H2/25H2) and NOT necessarily
# the OS build number of the image (e.g. 26300). Only the revision is therefore used.
function Get-RollupFromPackages {
    param([Parameter(Mandatory)]$Packages)
    $Best = $null
    foreach ($pkg in $Packages) {
        if ($pkg.PackageName -match '^Package_for_RollupFix~[^~]+~[^~]+~~(\d+)\.(\d+)\.') {
            $cand = [PSCustomObject]@{ Build = [int]$Matches[1]; Revision = [int]$Matches[2] }
            if (-not $Best -or
                $cand.Build -gt $Best.Build -or
                ($cand.Build -eq $Best.Build -and $cand.Revision -gt $Best.Revision)) {
                $Best = $cand
            }
        }
    }
    return $Best
}

# Reads OS build (CurrentBuildNumber), UBR and DisplayVersion from the SOFTWARE hive of the mounted image.
# Returns $null if the hive could not be read.
function Get-OfflineOSBuildInfo {
    param([Parameter(Mandatory)][string]$MountPath)

    $ErrorActionPreference = 'Continue'   # local: native stderr (reg.exe) must not abort
    $HiveFile = Join-Path $MountPath 'Windows\System32\config\SOFTWARE'
    $HiveName = 'WIMOST_OFFLINE_SW'
    $Info     = $null

    & reg.exe load "HKLM\$HiveName" $HiveFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }

    try {
        $cv = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\$HiveName\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        $Info = [PSCustomObject]@{
            Build          = [string]$cv.CurrentBuildNumber
            UBR            = [int]$cv.UBR
            DisplayVersion = [string]$cv.DisplayVersion
        }
    }
    catch { $Info = $null }
    finally {
        $cv = $null
        # Release open handles, otherwise unloading (and later the image unmount) fails
        for ($i = 1; $i -le 10; $i++) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKLM\$HiveName" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($LASTEXITCODE -ne 0) { Write-Log "Registry hive $HiveName could not be unloaded - the image unmount may fail." 'WARN' }
    }
    return $Info
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
$Mounted      = $false
$Success      = $false
$IsoMounted   = $false
$IsoFilePath  = $null
$OSDestBuild  = $null
$WorkWIM      = $null

if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$LogFile = Join-Path $LogRoot ("BuildMasterImage_{0}_{1}.log" -f $OSMain, (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    Write-Log "Start: OS $OSMain (index $ImageIndex)"

    foreach ($p in @($WimostRoot, $MountPath, $IsoDir)) {
        if (-not (Test-Path $p)) { throw "Path not found: $p (run Initialize-WIMOST.ps1 first)" }
    }

    # --- Clean up stale mount -------------------------------------------------
    $stale = Get-WindowsImage -Mounted | Where-Object { $_.Path.TrimEnd('\') -ieq $MountPath.TrimEnd('\') }
    if ($stale) {
        Write-Log "Stale mount found in $MountPath - discarding it." 'WARN'
        Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
    }
    Clear-WindowsCorruptMountPoint | Out-Null
    if (Get-ChildItem -Path $MountPath -Force -ErrorAction SilentlyContinue) {
        throw "Mount folder is not empty: $MountPath"
    }

    # --- Collect update files (fail fast before copying the large WIM) --------
    $CcuFiles         = @(Get-ChildItem -Path $CcuDir         -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab' })
    $LcuFiles         = @(Get-ChildItem -Path $LcuDir         -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab' })
    $DotNet           = @(Get-ChildItem -Path $DotNetDir      -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab' })
    $LangFiles        = @(Get-ChildItem -Path $LangDir        -File -Filter '*.cab' -ErrorAction SilentlyContinue)
    $LangFeatureFiles = @(Get-ChildItem -Path $LangFeatureDir -File -Filter '*.cab' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*Metadata*' })
    $FoDFiles         = @(Get-ChildItem -Path $FoDDir         -File -Filter '*.cab' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*Metadata*' })

    if ($LcuFiles.Count -eq 0) { throw "No LCU found in $LcuDir." }

    # --- Find ISO (newest ISO, first ISO\<OSMain>, then ISO) ------------------
    $FoundIso = $null
    foreach ($searchDir in @($IsoOsDir, $IsoDir)) {
        if (-not (Test-Path $searchDir)) { continue }
        $FoundIso = Get-ChildItem -Path $searchDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($FoundIso) { break }
    }
    if (-not $FoundIso) { throw "No ISO found in $IsoOsDir or $IsoDir." }
    Write-Log "Using ISO: $($FoundIso.FullName)"

    # --- Defender download ----------------------------------------------------
    if (Test-Path $DefenderRoot) { Remove-Item -Path $DefenderRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $DefenderExtract -Force | Out-Null

    $MaxRetries = 3
    $RetryDelay = 5
    $DownloadOk = $false
    for ($i = 1; $i -le $MaxRetries -and -not $DownloadOk; $i++) {
        Write-Log "MDATP download attempt $i of $MaxRetries..."
        try {
            Invoke-WebRequest -Uri $DefenderUrl -OutFile $DefenderExe -UseBasicParsing -ErrorAction Stop
            if ((Get-Item $DefenderExe).Length -le 1MB) { throw "File too small (<= 1 MB)." }

            $sig = Get-AuthenticodeSignature -FilePath $DefenderExe
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw "Invalid signature (status: $($sig.Status))."
            }
            $DownloadOk = $true
            Write-Log "MDATP download successful, signature valid."
        }
        catch {
            Write-Log "Download failed: $($_.Exception.Message)" 'WARN'
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelay }
        }
    }
    if (-not $DownloadOk) { throw "MDATP download failed after $MaxRetries attempts." }

    Write-Log "Extracting MDATP update..."
    $proc = Start-Process -FilePath $DefenderExe -ArgumentList '/x' -WorkingDirectory $DefenderExtract -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "MDATP extraction failed (exit code $($proc.ExitCode))." }

    # --- Copy install.wim from the ISO to the working copy --------------------
    if (-not (Test-Path $ImagesDir)) { New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null }
    if (Test-Path $TempWIM) { Remove-Item -Path $TempWIM -Force }

    $IsoFilePath = $FoundIso.FullName
    $MountedIso  = Mount-DiskImage -ImagePath $IsoFilePath -PassThru
    $IsoMounted  = $true
    $IsoLetter   = ($MountedIso | Get-Volume).DriveLetter
    if (-not $IsoLetter) { throw "Could not determine the drive letter of the mounted ISO." }
    $IsoWimPath  = '{0}:\sources\install.wim' -f $IsoLetter
    if (-not (Test-Path $IsoWimPath)) { throw "install.wim not found in the ISO: $IsoWimPath" }

    Write-Log "Copying install.wim from ISO to $TempWIM..."
    Copy-Item -Path $IsoWimPath -Destination $TempWIM -Force
    Set-ItemProperty -Path $TempWIM -Name IsReadOnly -Value $false

    Dismount-DiskImage -ImagePath $IsoFilePath | Out-Null
    $IsoMounted = $false

    # --- Read source build from the WIM ---------------------------------------
    $SrcInfo  = Get-WindowsImage -ImagePath $TempWIM -Index $ImageIndex
    $VerParts = @($SrcInfo.Version -split '\.')
    $SrcRev   = if ($VerParts.Count -ge 4) { $VerParts[3] } else { $SrcInfo.SPBuild }
    $OSSourceBuild = "{0}.{1}" -f $VerParts[2], $SrcRev
    Write-Log "Source image: '$($SrcInfo.ImageName)' (index $ImageIndex), build $OSSourceBuild"

    # --- Mount ----------------------------------------------------------------
    Mount-WindowsImage -Path $MountPath -ImagePath $TempWIM -Index $ImageIndex -CheckIntegrity | Out-Null
    $Mounted = $true
    Write-Log "Image mounted (index $ImageIndex)."

    # --- Install packages -----------------------------------------------------
    # Checkpoint CU(s) first, then the actual LCU
    Add-OfflinePackages -Files $CcuFiles         -Label 'Checkpoint CU' -ContinueOnError
    Add-OfflinePackages -Files $LcuFiles         -Label 'LCU'
    Add-OfflinePackages -Files $DotNet           -Label '.NET'
    Add-OfflinePackages -Files $LangFiles        -Label 'Language Pack'
    Add-OfflinePackages -Files $LangFeatureFiles -Label 'Language Feature'
    Add-OfflinePackages -Files $FoDFiles         -Label 'FoD'

    # --- Integrate MDATP ------------------------------------------------------
    if (-not (Test-Path $DefenderTarget)) { New-Item -ItemType Directory -Path $DefenderTarget -Force | Out-Null }
    Copy-Item -Path (Join-Path $DefenderExtract '*') -Destination $DefenderTarget -Force
    Write-Log "MDATP integrated into the WIM."

    # --- Integrate CMTrace ----------------------------------------------------
    if (Test-Path $CMTraceSource) {
        $System32Dir = Join-Path $MountPath 'Windows\System32'
        if (Test-Path $System32Dir) {
            Copy-Item -Path $CMTraceSource -Destination (Join-Path $System32Dir 'cmtrace.exe') -Force
            Write-Log "CMTrace copied to System32."
        }
    }
    else {
        Write-Log "CMTrace.exe not found at $CMTraceSource - skipped." 'WARN'
    }

    # --- Integrate FoD SXS sources --------------------------------------------
    if (Test-Path $SxsSourceDir) {
        if (-not (Test-Path $TargetSxsDir)) {
            New-Item -ItemType Directory -Path $TargetSxsDir -Force | Out-Null
        }
        Copy-Item -Path "$SxsSourceDir\*" -Destination $TargetSxsDir -Recurse -Force
        Write-Log "FoD SXS sources copied to Windows\sources\sxs."
    }
    else {
        Write-Log "SXS sources not found at $SxsSourceDir - skipped." 'WARN'
    }

    # --- INTERMEDIATE COMMIT (flush pending operations) -----------------------
    Write-Log "Performing intermediate commit to write package transactions..."
    Dismount-WindowsImage -Path $MountPath -Save -CheckIntegrity | Out-Null
    $Mounted = $false
    Start-Sleep -Seconds 5

    Write-Log "Remounting image for bloatware cleanup and optimization..."
    Mount-WindowsImage -Path $MountPath -ImagePath $TempWIM -Index $ImageIndex -CheckIntegrity | Out-Null
    $Mounted = $true

    # --- Bloatware cleanup (provisioned AppX packages in the offline WIM) -----
    Write-Log "Cleaning up provisioned AppX packages in the offline image..."
    $WhitelistedApps = @(
        'Microsoft.ApplicationCompatibilityEnhancements',
        'Microsoft.AsyncTextService',
        'Microsoft.AV1VideoExtension',
        'Microsoft.AVCEncoderVideoExtension',
        'Microsoft.DesktopAppInstaller',
        'Microsoft.ECApp',
        'Microsoft.GetHelp',
        'Microsoft.HEIFImageExtension',
        'Microsoft.HEVCVideoExtension',
        'Microsoft.HEVCVideoExtensions',
        'Microsoft.MicrosoftEdge*',
        'Microsoft.MicrosoftEdgeDevToolsClient',
        'Microsoft.MPEG2VideoExtension',
        'Microsoft.MsixPackagingTool',
        'Microsoft.Paint',
        'Microsoft.RawImageExtension',
        'Microsoft.ScreenSketch',
        'Microsoft.SecHealthUI',
        'Microsoft.StorePurchaseApp',
        'Microsoft.VP9VideoExtensions',
        'Microsoft.WebMediaExtensions',
        'Microsoft.WebpImageExtension',
        'Microsoft.Windows.NarratorQuickStart',
        'Microsoft.Windows.Photos',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCalculator',
        'Microsoft.WindowsCamera',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsNotepad',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsStore',
        'Microsoft.WindowsTerminal',
        'Microsoft.Winget.Source',
        'Microsoft.ZuneMusic',
        'NcsiUwpApp',
        'Microsoft.LanguageExperiencePack*',
        'Microsoft.Ink.Handwriting*',
        'Microsoft.LanguageFeatures*',
        'MicrosoftCorporationII.WinAppRuntime.*'
    )

    $ProvPackages = Get-AppxProvisionedPackage -Path $MountPath
    foreach ($ProvPkg in $ProvPackages) {
        $isProtected = $false
        foreach ($pattern in $WhitelistedApps) {
            if ($ProvPkg.DisplayName -like $pattern) {
                $isProtected = $true
                break
            }
        }

        if (-not $isProtected) {
            try {
                Write-Log "Removing provisioned app: $($ProvPkg.DisplayName)"
                Remove-AppxProvisionedPackage -Path $MountPath -PackageName $ProvPkg.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Could not remove $($ProvPkg.DisplayName): $_" 'WARN'
            }
        }
    }
    Write-Log "AppX bloatware cleanup completed."

    # --- Status checks, determine target build & optimization -----------------
    $InstalledPackages = @(Get-WindowsPackage -Path $MountPath)

    $InstalledPackages |
        Sort-Object PackageState |
        Format-Table PackageState, PackageName -AutoSize |
        Out-String -Width 300 |
        Out-File -FilePath $PackageListFile -Encoding utf8

    # Revision from the highest RollupFix package, OS build number from the registry of the image
    $Rollup = Get-RollupFromPackages -Packages $InstalledPackages
    if (-not $Rollup) {
        throw "Could not determine the target build (no Package_for_RollupFix in the image). See $PackageListFile."
    }

    $OsInfo = Get-OfflineOSBuildInfo -MountPath $MountPath
    if ($OsInfo -and $OsInfo.Build -match '^\d+$') {
        $BuildMajor = $OsInfo.Build
        Write-Log ("Image registry: CurrentBuildNumber {0}, UBR {1}, DisplayVersion '{2}'" -f $OsInfo.Build, $OsInfo.UBR, $OsInfo.DisplayVersion)
        if ($OsInfo.UBR -ne $Rollup.Revision) {
            Write-Log "UBR in the registry ($($OsInfo.UBR)) differs from the RollupFix revision ($($Rollup.Revision)) - using the RollupFix revision." 'WARN'
        }
    }
    else {
        $BuildMajor = $VerParts[2]
        Write-Log "OS build could not be read from the image registry - using the build from the source WIM ($BuildMajor)." 'WARN'
    }

    $OSDestBuild = "{0}.{1}" -f $BuildMajor, $Rollup.Revision
    Write-Log "RollupFix package: $($Rollup.Build).$($Rollup.Revision) | Target build: $OSDestBuild (source: $OSSourceBuild)"
    if ([string]$Rollup.Revision -eq [string]$SrcRev) {
        Write-Log "Revision equals the source image - the LCU did not change the build." 'WARN'
    }

    Invoke-Dism -Step 'Optimize-ProvisionedAppxPackages' -Arguments @("/Image:$MountPath", '/Optimize-ProvisionedAppxPackages')

    # --- Final unmount, export & compression ----------------------------------
    Dismount-WindowsImage -Path $MountPath -Save -CheckIntegrity | Out-Null
    $Mounted = $false

    if (Test-Path $NewWIM) { Remove-Item -Path $NewWIM -Force }
    Export-WindowsImage -SourceImagePath $TempWIM -SourceIndex $ImageIndex `
        -DestinationImagePath $NewWIM -CompressionType Max -CheckIntegrity | Out-Null

    $WorkWIM = Join-Path $ImagesDir "$OSDestBuild.wim"
    Move-Item -Path $NewWIM -Destination $WorkWIM -Force
    Write-Log "WIM ready: $WorkWIM"

    $Success = $true
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) 'ERROR'
    $global:LASTEXITCODE = 1
}
finally {
    if ($Mounted) {
        try { Dismount-WindowsImage -Path $MountPath -Discard | Out-Null } catch { & dism.exe /Cleanup-Wim | Out-Host }
    }
    if ($IsoMounted -and $IsoFilePath) {
        try { Dismount-DiskImage -ImagePath $IsoFilePath | Out-Null } catch { }
    }
    if (Test-Path $NewWIM) { Remove-Item -Path $NewWIM -Force -ErrorAction SilentlyContinue }
    if ($Success -and -not $KeepTemp -and (Test-Path $TempWIM)) { Remove-Item -Path $TempWIM -Force -ErrorAction SilentlyContinue }
    Stop-Transcript | Out-Null
}

if (-not $Success) { exit 1 }
