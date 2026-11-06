#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a bootable Windows 11 ISO (BIOS + UEFI) from the original Microsoft ISO and the serviced
    master WIM built by Build-MasterImage.ps1.

.DESCRIPTION
    Part of the WIM Offline Servicing Toolkit (WIMOST).

    - Uses the newest ISO in WIMOST\ISO\<OSMain> (fallback: WIMOST\ISO) as the template. Its content is
      copied to a staging folder, except sources\install.wim / install.esd.
    - Uses the finished WIM from Build-MasterImage.ps1 (newest <build>.<revision>.wim in the images
      folder, or the file given with -WimPath) as sources\install.wim.
    - Builds a dual-boot (BIOS + UEFI) ISO with oscdimg.exe (UDF 1.02, so a WIM larger than 4 GB is
      no problem). The volume label of the original ISO is kept unless -VolumeLabel is given.
    - Verifies the result by mounting the new ISO (boot files present, install.wim readable).
    - The ISO is written to the images folder, NOT to WIMOST\ISO, so that Build-MasterImage.ps1 never
      picks up a customized ISO as its source.
    - Writes a transcript to <MainDrive>\WIMOST\Logs\BuildIso_<OSMain>_<timestamp>.log. Exit code 1 on
      failure.

    oscdimg.exe is part of the "Deployment Tools" of the Windows ADK. It is searched in this order:
    -OscdimgPath, <MainDrive>\WIMOST\Tools\oscdimg\oscdimg.exe, the default ADK folders, PATH.

.PARAMETER MainDrive
    Drive that holds the WIMOST structure. Default: C:

.PARAMETER OSMain
    OS release name used for the folder structure (e.g. 26H2). Must match the value used with the
    other WIMOST scripts.

.PARAMETER WimPath
    Path of the WIM that becomes sources\install.wim. Default: the newest *.wim (without Temp_*.wim) in
    the images folder.

.PARAMETER ImagesPath
    Folder with the finished WIM and target folder of the ISO. Default: <MainDrive>\WIMOST\Images

.PARAMETER OutputPath
    Full path of the ISO file to create. Default: <ImagesPath>\<name of the WIM>.iso
    (for example 26300.9725.iso).

.PARAMETER OscdimgPath
    Full path of oscdimg.exe if it is not found automatically.

.PARAMETER VolumeLabel
    Volume label of the ISO (max. 32 characters, letters, digits, '_' and '-'). Default: label of the
    original ISO.

.PARAMETER NoPrompt
    Use the "no prompt" UEFI boot image (efisys_noprompt.bin), so the "Press any key to boot from CD or
    DVD" message does not appear. Useful for unattended installations.

.PARAMETER DisableLangPackCleanup
    Windows removes preinstalled language packs that are not in the user's language list after a
    Setup-based installation (scheduled task LPRemove). This switch adds a SetupComplete.cmd to the ISO
    (sources\$OEM$\$$\Setup\Scripts) that runs after Setup and
      - disables the scheduled tasks "Pre-staged app cleanup", "LPRemove" and "Uninstallation"
        (LanguageComponentsInstaller),
      - sets HKLM\SOFTWARE\Policies\Microsoft\Control Panel\International\
        BlockCleanupOfUnusedPreinstalledLangPacks = 1.
    The WIM itself stays unchanged. See
    https://learn.microsoft.com/azure/virtual-desktop/windows-11-language-packs
    The script writes C:\Windows\Temp\WIMOST_SetupComplete.log on the installed computer.

.PARAMETER KeepStaging
    Keep the staging folder (WIMOST\ISOSTAGE) after a successful run.

.PARAMETER Force
    Overwrite an existing ISO file.

.EXAMPLE
    .\New-BootableIso.ps1 -MainDrive D: -OSMain 26H2

    Builds D:\WIMOST\Images\<build>.<revision>.iso from the newest ISO in D:\WIMOST\ISO\26H2 and the
    newest WIM in D:\WIMOST\Images.

.EXAMPLE
    .\New-BootableIso.ps1 -MainDrive D: -WimPath E:\Images\26300.9725.wim -NoPrompt -Force

    Uses a specific WIM, the no-prompt boot image and overwrites an existing ISO.

.NOTES
    Version : 1.0.0
    License : MIT
    The ISO contains only the edition that was exported by Build-MasterImage.ps1 (a single image).
    boot.wim (Windows PE / Setup) is taken unchanged from the original ISO.
#>
[CmdletBinding()]
param(
    [string]$MainDrive = "C:",
    [string]$OSMain    = "26H2",
    [string]$WimPath,
    [string]$ImagesPath,
    [string]$OutputPath,
    [string]$OscdimgPath,
    [string]$VolumeLabel,
    [switch]$NoPrompt,
    [switch]$DisableLangPackCleanup,
    [switch]$KeepStaging,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$WimostRoot = Join-Path $MainDrive  'WIMOST'
$LogRoot    = Join-Path $WimostRoot 'Logs'
$IsoDir     = Join-Path $WimostRoot 'ISO'
$IsoOsDir   = Join-Path $IsoDir     $OSMain
$ToolsDir   = Join-Path $WimostRoot 'Tools'
$StageDir   = Join-Path $WimostRoot 'ISOSTAGE'
$ImagesDir  = if ($ImagesPath) { $ImagesPath } else { Join-Path $WimostRoot 'Images' }

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

function Find-Oscdimg {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) { return (Resolve-Path -LiteralPath $ExplicitPath).Path }
        throw "oscdimg.exe not found at the given -OscdimgPath: $ExplicitPath"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $ToolsDir 'oscdimg\oscdimg.exe'))
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) { continue }
        $candidates.Add((Join-Path $base 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'))
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $cmd = Get-Command -Name 'oscdimg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    throw ("oscdimg.exe not found. Install the 'Deployment Tools' of the Windows ADK, or copy oscdimg.exe " +
           "to '$(Join-Path $ToolsDir 'oscdimg')', or pass -OscdimgPath.")
}

function Assert-FreeSpace {
    param([string]$Path, [long]$RequiredBytes, [string]$Purpose)
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path)
    if (-not $root -or $root.StartsWith('\\')) { return }   # UNC path: cannot be checked reliably
    $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    if ($free -lt $RequiredBytes) {
        throw ("Not enough free space on {0} for {1}: {2:N1} GB free, about {3:N1} GB required." -f
               $root, $Purpose, ($free / 1GB), ($RequiredBytes / 1GB))
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
$Success    = $false
$IsoMounted = $null    # path of the ISO that is currently mounted (source or verification)
$PartIso    = $null

if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$LogFile = Join-Path $LogRoot ("BuildIso_{0}_{1}.log" -f $OSMain, (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    Write-Log "Start: OS $OSMain"

    foreach ($p in @($WimostRoot, $IsoDir)) {
        if (-not (Test-Path $p)) { throw "Path not found: $p (run Initialize-WIMOST.ps1 first)" }
    }

    # --- Tools ----------------------------------------------------------------
    $Oscdimg = Find-Oscdimg -ExplicitPath $OscdimgPath
    Write-Log "Using oscdimg: $Oscdimg"

    # --- Source ISO (newest ISO, first ISO\<OSMain>, then ISO) -----------------
    $FoundIso = $null
    foreach ($searchDir in @($IsoOsDir, $IsoDir)) {
        if (-not (Test-Path $searchDir)) { continue }
        $FoundIso = Get-ChildItem -Path $searchDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($FoundIso) { break }
    }
    if (-not $FoundIso) { throw "No ISO found in $IsoOsDir or $IsoDir." }
    Write-Log "Template ISO: $($FoundIso.FullName)"

    # --- WIM ------------------------------------------------------------------
    if ($WimPath) {
        if (-not (Test-Path -LiteralPath $WimPath -PathType Leaf)) { throw "WIM not found: $WimPath" }
        $Wim = Get-Item -LiteralPath $WimPath
    }
    else {
        if (-not (Test-Path $ImagesDir)) { throw "Images folder not found: $ImagesDir (run Build-MasterImage.ps1 first)" }
        $Wim = Get-ChildItem -Path $ImagesDir -Filter '*.wim' -File |
               Where-Object { $_.Name -notlike 'Temp_*' } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $Wim) { throw "No finished WIM found in $ImagesDir (run Build-MasterImage.ps1 first or use -WimPath)." }
    }
    $WimImages = @(Get-WindowsImage -ImagePath $Wim.FullName)
    if ($WimImages.Count -eq 0) { throw "No image found in $($Wim.FullName)." }
    foreach ($img in $WimImages) {
        Write-Log ("WIM: {0} | index {1}: '{2}' | version {3}" -f $Wim.Name, $img.ImageIndex, $img.ImageName, $img.Version)
    }
    if ($WimImages.Count -gt 1) { Write-Log "The WIM contains $($WimImages.Count) images - all of them will be part of the ISO." 'WARN' }

    # --- Output ---------------------------------------------------------------
    if (-not $OutputPath) {
        $OutputPath = Join-Path $ImagesDir ([System.IO.Path]::GetFileNameWithoutExtension($Wim.Name) + '.iso')
    }
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ($OutputPath.StartsWith($IsoDir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The output ISO must not be written below $IsoDir (Build-MasterImage.ps1 would use it as source ISO)."
    }
    if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
        throw "Output ISO already exists: $OutputPath (use -Force to overwrite)."
    }
    $OutDir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    # The temp file must keep the .iso extension, otherwise Mount-DiskImage cannot mount it for verification
    $PartIso = "$OutputPath.part.iso"

    # --- Free space (staging holds the ISO content without install.wim plus the new WIM) ---
    Assert-FreeSpace -Path $WimostRoot -RequiredBytes ($FoundIso.Length + $Wim.Length) -Purpose 'the staging folder'

    # --- Staging: ISO content without install.wim ----------------------------
    if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

    $MountedIso = Mount-DiskImage -ImagePath $FoundIso.FullName -PassThru -ErrorAction Stop
    $IsoMounted = $FoundIso.FullName
    $IsoVolume  = $MountedIso | Get-Volume
    if (-not $IsoVolume.DriveLetter) { throw "Could not determine the drive letter of the mounted ISO." }
    $IsoRoot    = '{0}:\' -f $IsoVolume.DriveLetter
    $SrcLabel   = [string]$IsoVolume.FileSystemLabel

    Write-Log "Copying ISO content to $StageDir (without install.wim / install.esd)..."
    & robocopy.exe $IsoRoot $StageDir /E /XF install.wim install.esd /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit code $LASTEXITCODE)." }

    Dismount-DiskImage -ImagePath $FoundIso.FullName | Out-Null
    $IsoMounted = $null

    # Files copied from an ISO are read-only
    & attrib.exe -R "$StageDir\*" /S /D | Out-Null

    # --- Boot files -----------------------------------------------------------
    $BiosBoot = Join-Path $StageDir 'boot\etfsboot.com'
    $UefiName = if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }
    $UefiBoot = Join-Path $StageDir "efi\microsoft\boot\$UefiName"
    foreach ($f in @($BiosBoot, $UefiBoot)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Boot file not found in the template ISO: $f" }
    }

    # --- Insert the serviced WIM ---------------------------------------------
    $TargetWim = Join-Path $StageDir 'sources\install.wim'
    if (-not (Test-Path (Split-Path $TargetWim -Parent))) { throw "Folder 'sources' is missing in the template ISO." }
    Write-Log "Copying $($Wim.Name) to sources\install.wim..."
    Copy-Item -LiteralPath $Wim.FullName -Destination $TargetWim -Force

    # --- Optional: keep the language packs after Setup ------------------------
    if ($DisableLangPackCleanup) {
        $ScriptsDir = Join-Path $StageDir 'sources\$OEM$\$$\Setup\Scripts'
        $SetupComplete = Join-Path $ScriptsDir 'SetupComplete.cmd'
        if (Test-Path -LiteralPath $SetupComplete) {
            Write-Log "The template ISO already contains a SetupComplete.cmd - it is replaced." 'WARN'
        }
        New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
        $Cmd = @'
@echo off
rem Added by WIMOST (New-BootableIso.ps1 -DisableLangPackCleanup): keep preinstalled language packs
set LOG=%windir%\Temp\WIMOST_SetupComplete.log
echo %date% %time% Disable language pack cleanup > "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; Disable-ScheduledTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'Pre-staged app cleanup'; Disable-ScheduledTask -TaskPath '\Microsoft\Windows\MUI\' -TaskName 'LPRemove'; Disable-ScheduledTask -TaskPath '\Microsoft\Windows\LanguageComponentsInstaller\' -TaskName 'Uninstallation'" >> "%LOG%" 2>&1
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Control Panel\International" /v BlockCleanupOfUnusedPreinstalledLangPacks /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
exit /b 0
'@
        Set-Content -LiteralPath $SetupComplete -Value $Cmd -Encoding Ascii
        Write-Log "SetupComplete.cmd added (language pack cleanup disabled after Setup)."
    }

    # --- Volume label ---------------------------------------------------------
    $Label = if ($VolumeLabel) { $VolumeLabel } elseif ($SrcLabel) { $SrcLabel } else { 'WIMOST' }
    $Label = ($Label -replace '[^A-Za-z0-9_-]', '_')
    if ($Label.Length -gt 32) { $Label = $Label.Substring(0, 32) }
    Write-Log "Volume label: $Label"

    # --- Build the ISO --------------------------------------------------------
    $StagedBytes = (Get-ChildItem -Path $StageDir -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    Assert-FreeSpace -Path $OutDir -RequiredBytes ([long]$StagedBytes + 1GB) -Purpose 'the ISO file'

    if (Test-Path -LiteralPath $PartIso) { Remove-Item -LiteralPath $PartIso -Force }

    $BootData = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $BiosBoot, $UefiBoot
    $OscArgs  = '-m -o -u2 -udfver102 -l{0} -bootdata:{1} "{2}" "{3}"' -f $Label, $BootData, $StageDir, $PartIso

    Write-Log "Running oscdimg (UDF 1.02, BIOS + UEFI, $UefiName)..."
    $proc = Start-Process -FilePath $Oscdimg -ArgumentList $OscArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "oscdimg failed (exit code $($proc.ExitCode))." }
    if (-not (Test-Path -LiteralPath $PartIso) -or (Get-Item -LiteralPath $PartIso).Length -le 0) {
        throw "oscdimg did not create the ISO file."
    }

    # --- Verify the new ISO ---------------------------------------------------
    Write-Log "Verifying the new ISO..."
    $VerifyIso = Mount-DiskImage -ImagePath $PartIso -PassThru -ErrorAction Stop
    $IsoMounted = $PartIso
    $VerLetter = ($VerifyIso | Get-Volume).DriveLetter
    if (-not $VerLetter) { throw "Could not mount the new ISO for verification." }
    $VerRoot = '{0}:\' -f $VerLetter
    foreach ($rel in @('sources\install.wim', 'sources\boot.wim', 'boot\etfsboot.com', "efi\microsoft\boot\$UefiName", 'efi\boot\bootx64.efi', 'setup.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $VerRoot $rel))) { throw "Verification failed: '$rel' is missing in the new ISO." }
    }
    $VerImages = @(Get-WindowsImage -ImagePath (Join-Path $VerRoot 'sources\install.wim'))
    if ($VerImages.Count -ne $WimImages.Count) { throw "Verification failed: unexpected number of images in the ISO's install.wim." }
    Dismount-DiskImage -ImagePath $PartIso | Out-Null
    $IsoMounted = $null

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    Move-Item -LiteralPath $PartIso -Destination $OutputPath -Force
    $PartIso = $null

    Write-Log ("ISO ready: {0} ({1:N2} GB)" -f $OutputPath, ((Get-Item -LiteralPath $OutputPath).Length / 1GB))
    $Success = $true
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) 'ERROR'
    $global:LASTEXITCODE = 1
}
finally {
    if ($IsoMounted) {
        try { Dismount-DiskImage -ImagePath $IsoMounted -ErrorAction Stop | Out-Null } catch { }
    }
    if ($PartIso -and (Test-Path -LiteralPath $PartIso)) { Remove-Item -LiteralPath $PartIso -Force -ErrorAction SilentlyContinue }
    if ($Success -and -not $KeepStaging -and (Test-Path $StageDir)) {
        Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Stop-Transcript | Out-Null
}

if (-not $Success) { exit 1 }
