# WIM Offline Servicing Toolkit (WIMOST)

PowerShell scripts that build an up-to-date **Windows 11 master WIM** by servicing the `install.wim` of an ISO **offline**. The result is a patched, cleaned-up image that is ready to be imported into your deployment solution (MECM/SCCM, MDT, DeployR, ...).

| Script | Purpose |
| --- | --- |
| [`Initialize-WIMOST.ps1`](Initialize-WIMOST.ps1) | Creates the working folder structure and downloads the latest Cumulative Update (including checkpoint CUs) and .NET Framework update from the Microsoft Update Catalog. |
| [`Build-MasterImage.ps1`](Build-MasterImage.ps1) | Mounts the `install.wim` from the newest ISO, integrates all updates and components, cleans up AppX packages and exports the finished WIM. |
| [`New-BootableIso.ps1`](New-BootableIso.ps1) | Optional. Packs the finished WIM together with the original Microsoft ISO content into a new bootable (BIOS + UEFI) ISO. |

## Features

- **Fully automated update download** from the Microsoft Update Catalog (x64, no previews, no Insider builds, no Server or Dynamic Updates) with previous-month fallback.
- **Checkpoint cumulative update handling**: prerequisites of the LCU are separated automatically and installed first.
- **Safe downloads**: files are written as `.part` and renamed only when complete; web requests are retried.
- **Offline servicing** of the `install.wim` taken straight from the ISO: checkpoint CU, LCU, .NET, language packs, language features, Features on Demand.
- **Defender signatures**: latest definition update is downloaded, its Authenticode signature is verified, and it is integrated into the image.
- **Extras**: `cmtrace.exe` and the FoD SXS sources can be added to the image.
- **AppX cleanup**: removes provisioned AppX packages that are not on an allow list, followed by `Optimize-ProvisionedAppxPackages`.
- **Correct build naming**: the output is named `<OS build>.<revision>.wim` (e.g. `26300.9725.wim`), derived from the image itself.
- **Bootable ISO** (optional): the finished WIM is merged with the original ISO content into a new dual-boot ISO (BIOS + UEFI, UDF) and verified.
- **Logging**: transcript per run, list of installed packages, exit code `1` on failure.
- **Robust cleanup**: stale mounts are discarded at start; the image is dismounted even if a step fails.

## Requirements

- Windows 10/11 or Windows Server with **Windows PowerShell 5.1**
- **Administrator** rights (both scripts use `#Requires -RunAsAdministrator`)
- The built-in `Dism` PowerShell module (no Windows ADK required)
- Internet access to `catalog.update.microsoft.com`, the Microsoft download hosts and `go.microsoft.com`
- A Windows 11 **ISO** of the release you want to build (e.g. 26H2)
- Enough free disk space for the ISO, the working WIM and the exported WIM (plan for several times the size of the `install.wim`)
- Optional: language pack and Feature on Demand `.cab` files, `cmtrace.exe`, FoD SXS sources
- Optional, only for `New-BootableIso.ps1`: `oscdimg.exe` from the *Deployment Tools* of the [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) (installed ADK is detected automatically; alternatively copy `oscdimg.exe` to `WIMOST\Tools\oscdimg\` or use `-OscdimgPath`)

## Folder structure

`Initialize-WIMOST.ps1` creates the following structure below `<MainDrive>\WIMOST` (default drive: `C:`):

```
C:\WIMOST\
  ISO\<OSMain>\              Windows 11 ISO (newest ISO is used)
  LCU\<OSMain>\              Latest Cumulative Update          (downloaded)
  CCU\<OSMain>\              Checkpoint Cumulative Updates     (downloaded)
  DOTNET\<OSMain>\           .NET Framework update             (downloaded)
  LANGUAGES\<OSMain>\        Language pack .cab files          (you provide)
  LANG_FEATURES\<OSMain>\    Language feature .cab files       (you provide)
    metadata\
  FODS\<OSMain>\             Feature on Demand .cab files      (you provide)
    metadata\
  Tools\
    cmtrace.exe              Optional, copied to System32 of the image
    oscdimg\oscdimg.exe      Optional, only if the Windows ADK is not installed
    sources\sxs\             Optional, copied to Windows\sources\sxs of the image
  MDATP\                     Defender signatures, created and cleared by Build-MasterImage.ps1
  ISOSTAGE\                  Temporary staging folder of New-BootableIso.ps1
  MOUNT\                     Mount point for the image
  Logs\                      Transcripts
  Images\                    Working WIM, finished WIM and new ISO (default, see -ImagesPath)
  Packages.txt               Package list of the last build
```

`<OSMain>` is the release name you pass with `-OSMain` (e.g. `26H2`).

> Language packs, Features on Demand, the ISO, `cmtrace.exe` and the SXS sources are **not** downloaded. Copy them into the folders above (e.g. from the Language Pack ISO and the FoD ISO). `cmtrace.exe` is part of the Configuration Manager tools and is not included in this repository.

## Usage

### 1. Initialize and download updates

```powershell
.\Initialize-WIMOST.ps1 -MainDrive C: -OSMain 26H2
```

### 2. Provide the remaining content

- Copy the Windows 11 ISO to `C:\WIMOST\ISO\26H2`.
- Optionally copy language packs, language features and FoDs, `cmtrace.exe` and the SXS sources into their folders.

### 3. Build the master image

List the editions in your ISO's `install.wim` first to find the right index:

```powershell
Get-WindowsImage -ImagePath <path to install.wim>
```

Then build:

```powershell
.\Build-MasterImage.ps1 -MainDrive D: -OSMain 26H2 -ImageIndex 6
```

The finished image is written to `C:\WIMOST\Images\<OS build>.<revision>.wim`.

### 4. Create a bootable ISO (optional)

```powershell
.\New-BootableIso.ps1 -MainDrive D: -OSMain 26H2
```

The script takes the newest ISO from `ISO\<OSMain>` as a template, replaces `sources\install.wim` with the newest finished WIM from the images folder and writes `<OS build>.<revision>.iso` next to the WIM. The new ISO is mounted and checked at the end.

- The ISO is **not** written to `WIMOST\ISO`, so `Build-MasterImage.ps1` never uses it as its source.
- The ISO contains only the edition that was exported by `Build-MasterImage.ps1`. `boot.wim` is taken unchanged from the original ISO.
- Windows Setup removes preinstalled language packs that are not in the user's language list (scheduled task `LPRemove`). Use `-DisableLangPackCleanup` to keep them; MECM task sequences usually do this in a separate step.
- `-NoPrompt` uses the no-prompt UEFI boot image (no "Press any key to boot from CD or DVD"), which helps with unattended installations.

## Parameters

### Initialize-WIMOST.ps1

| Parameter | Default | Description |
| --- | --- | --- |
| `-MainDrive` | `C:` | Drive for the WIMOST structure. |
| `-OSMain` | `26H2` | OS release name used for folders and as the default Catalog search term. |
| `-CatalogOSName` | `<OSMain>` | Name used in the Catalog search if the Catalog lists the updates under another name. |
| `-CheckpointDir` | `<MainDrive>\WIMOST\CCU\<OSMain>` | Target folder for checkpoint CUs. |
| `-LcuQueryTemplate` | `{0} Cumulative Update for Windows 11 {1}` | Catalog search template for the LCU. `{0}` = `yyyy-MM`, `{1}` = `CatalogOSName`. |
| `-DotNetQueryTemplate` | `{0} Cumulative Update for .NET Framework Windows 11 {1}` | Catalog search template for the .NET update. |

### Build-MasterImage.ps1

| Parameter | Default | Description |
| --- | --- | --- |
| `-MainDrive` | `C:` | Drive that holds the WIMOST structure. |
| `-OSMain` | `26H2` | OS release name. Must match the value used for initialization. |
| `-ImageIndex` | `3` | Edition index inside the ISO's `install.wim`. Depends on the ISO. |
| `-ImagesPath` | `<MainDrive>\WIMOST\Images` | Folder for the working and the finished WIM. A local path is recommended. |
| `-KeepTemp` | off | Keep the temporary working WIM after a successful run. |

### New-BootableIso.ps1

| Parameter | Default | Description |
| --- | --- | --- |
| `-MainDrive` | `C:` | Drive that holds the WIMOST structure. |
| `-OSMain` | `26H2` | OS release name. Must match the value used for initialization. |
| `-WimPath` | newest finished WIM in `-ImagesPath` | WIM that becomes `sources\install.wim`. |
| `-ImagesPath` | `<MainDrive>\WIMOST\Images` | Folder with the finished WIM and target folder of the ISO. |
| `-OutputPath` | `<ImagesPath>\<WIM name>.iso` | Full path of the ISO file. Must not be below `WIMOST\ISO`. |
| `-OscdimgPath` | auto-detect | Path of `oscdimg.exe`. |
| `-VolumeLabel` | label of the original ISO | Volume label (max. 32 characters). |
| `-NoPrompt` | off | Use `efisys_noprompt.bin` for UEFI boot. |
| `-DisableLangPackCleanup` | off | Add a `SetupComplete.cmd` that disables the language pack cleanup (`LPRemove` etc.) so preinstalled languages stay available after a Setup-based installation. |
| `-KeepStaging` | off | Keep the staging folder after a successful run. |
| `-Force` | off | Overwrite an existing ISO. |

## How the build works

1. Discard stale mounts, collect update files (fail fast if no LCU is present).
2. Select the newest ISO (`ISO\<OSMain>` first, then `ISO`).
3. Download and verify the Defender signature update.
4. Mount the ISO and copy `install.wim` to a working copy; unmount the ISO.
5. Mount the working copy and install: checkpoint CU(s), LCU, .NET, language packs, language features, FoDs.
6. Integrate Defender signatures, `cmtrace.exe` and SXS sources.
7. Intermediate commit to flush pending package transactions, then remount.
8. Remove provisioned AppX packages that are not on the allow list.
9. Determine the target build, run `Optimize-ProvisionedAppxPackages`, unmount and save.
10. Export the image with maximum compression to `<OS build>.<revision>.wim`.

### How the output file name is derived

- The **OS build number** (e.g. `26300`) is read from `CurrentBuildNumber` in the SOFTWARE registry hive of the mounted image.
- The **revision** (e.g. `9725`) comes from the highest `Package_for_RollupFix` in the image.
- The build part of the `Package_for_RollupFix` name is the *servicing branch* (e.g. `26100`, shared by several releases) and is deliberately not used for the file name.

## Customization

- **AppX allow list**: edit `$WhitelistedApps` in `Build-MasterImage.ps1`. Every provisioned AppX package that does not match an entry is removed from the image. Review the list before your first build.
- **Catalog search**: if the Catalog stops finding updates, adjust `-CatalogOSName`, `-LcuQueryTemplate` or `-DotNetQueryTemplate`.

## Notes and limitations

- The Microsoft Update Catalog has **no official API**. `Initialize-WIMOST.ps1` parses its public web pages and may stop working if Microsoft changes them.
- Always test the resulting image in a lab before using it in production.
- This project is not affiliated with or endorsed by Microsoft. Use at your own risk.

## License

Released under the [MIT License](LICENSE).
