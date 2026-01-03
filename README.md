# Baseliner App Scripts

This repository contains a PowerShell-based automation toolkit under `app/` with a shared execution contract and logging model. It is intended for Windows environments and is organized around admin and user workflows, reusable libraries, and operation schemas.

## Contents

### Top-level scripts (`app/`)
- **Admin\***: system-level setup and maintenance tasks (administrator required).
- **User\***: per-user setup and maintenance tasks (run in user context).
- **AdminSetup.ps1**: orchestrator that loads configuration and runs scripted tasks.
- **AdminUserSetup.ps1 / AdminUserSetupFromActiveSetup.ps1**: user-side setup entry points invoked by admin or Active Setup.
- **UserLogon.* / UserLogonTracker.ps1**: logon-time tasks and telemetry helpers.
- **Create-Administrator.ps1**: creates or configures a local admin account.
- **StatusStartup.ps1**: reports or validates startup status.
- **GenericBatchOperator.ps1**: shared batch runner for declarative operations.

### Libraries (`app/lib/`)
Reusable modules for file, registry, firewall, scheduling, logging, and phase handling. Notable modules include:
- `Logger.psm1` and `Phase*.psm1` for contract-aligned logging and execution phases.
- `LoadScriptConfig.psm1` for config loading.
- `File*`, `Registry*`, and `Firewall*` modules for common operations.

### Schemas (`app/schemas/`)
Schema documentation for declarative operations:
- `common.md`, `ordered-batch.md`, `app.md`, `file.md`, `registry.md`, `firewall.md`, `outputs.md`
- Index: `app/OPERATIONS_SCHEMA.md`

### Tools (`app/tools/`)
- `Validate-Logs.ps1`: validation utility for log output.

## Execution contract and logging
Behavior is governed by:
- `app/CONTRACT.md`: canonical result counters and intent metadata.
- `app/LOGGING.md`: logging levels and required semantics.

These documents are the source of truth for result reporting and log wording.

## Requirements
- Windows PowerShell 5.1
- Administrator privileges for `Admin*` scripts

## Notes
- Scripts are configuration-driven and typically load config via `lib/LoadScriptConfig.psm1`.
- The setup workflow and profile selection live outside `app/` (see `setup.core.ps1`).

## License
Add project license info here.
