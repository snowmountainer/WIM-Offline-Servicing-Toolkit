# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0]

Initial public release.

### Added

- `Initialize-WIMOST.ps1` 1.0.0: creates the WIMOST folder structure and downloads the latest LCU, checkpoint CU and .NET update from the Microsoft Update Catalog (with previous-month fallback, `.part` downloads, retries and a summary).
- `Build-MasterImage.ps1` 1.0.0: offline servicing of the `install.wim` from an ISO (checkpoint CU, LCU, .NET, language packs, language features, FoDs, Defender signatures, CMTrace, SXS sources, AppX cleanup) and export as `<OS build>.<revision>.wim`.
- `-ImagesPath` parameter for the output location of `Build-MasterImage.ps1` (default `<MainDrive>\WIMOST\Images`).
