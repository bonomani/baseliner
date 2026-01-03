# Tests

This folder contains PowerShell test scripts and runners for Baseliner operations.

## Run the full suite (4 passes)

Run a set of four runs: only invalid definitions, invalid state, happy path (clean), happy path (idempotent).

```powershell
powershell -File .\RunAllTests.ps1 -Debug -SkipRegistry -SkipCom
```

Use `-SkipRegistry` or `-SkipCom` if your environment should not touch registry or COM.
`-SkipRegistry` skips `TestRegistrySetKeyValue.ps1` in the runner.
The four-pass runner controls which sections run by setting the test mode internally.

## Run a single pass

```powershell
powershell -File .\RunAllTests.ps1 -Debug -Modes HappyClean
```

## Run a single test

```powershell
powershell -File .\TestFileCopy.ps1 -Debug -Mode HappyClean
```
```powershell
powershell -File .\TestFileSplit.ps1 -Debug -Mode HappyClean
```
```powershell
powershell -File .\TestFileJoin.ps1 -Debug -Mode HappyClean
```

```powershell
powershell -File .\RunSingleTest.ps1 -TestName TestFirewallSetRule.ps1 -Debug
```

## Common flags

- `-Debug`: increase verbosity in logs and console output.
- `-SkipRegistry`: skip registry tests in the runner.
- `-SkipCom`: skip COM-based operations (if a test supports it).
- `-Mode`: one of `InvalidDefinition`, `InvalidState`, `HappyClean`, `HappyIdempotent`.
- `-TestName`: used by `RunSingleTest.ps1` to target a specific test file.

## Notes

- Logs are written under `tests/logs` (for example, `tests/logs/test-filecopy.log`).
- Temporary test folders are named `tmp-*` under `tests/`.
- `TestFileSplitJoin.ps1` was split into `TestFileSplit.ps1` and `TestFileJoin.ps1`.
- `TestFileNewUrlShortcut.ps1` always uses `.url` mode with `SkipCom` forced in the test; runner `-SkipCom` has no effect there for now.
- Only one test mode should be active at a time; the tests will flag it if multiple are used.
