# App/Package Operations (category: app)
This document defines batch operations that manage applications, provisioned apps,
package managers, and app plugins.

## TODO / NOT IMPLEMENTED
This schema is documented but not implemented in the runtime yet.
See also:
- `app/schemas/common.md`

### Category model
Operations in this category are not uniform; each operation has its own execution model.
Fields below are derived from current script behaviors.

Common envelope: see `app/schemas/common.md` (operation + context + items).

### remove-appx (UserRemoveApps.ps1)
Removes installed Appx packages for the current user.

Target: app package name (Appx package name).

Required fields (per item):
- `name`: Appx package name used with `Get-AppxPackage -Name`.

Behavior:
- Observes by querying `Get-AppxPackage`.
- If not installed, `NOTICE` with `Reason=missing`.
- If installed, calls `Remove-AppxPackage`.
- Failures are logged as `ERROR` and increment `Failed`.

Example (NOT IMPLEMENTED):
```json
{
  "operation": "remove-appx",
  "items": [
    { "name": "Microsoft.BingWeather" },
    { "name": "Microsoft.XboxApp" }
  ]
}
```

### remove-provisioned-appx (AdminRemoveProvisionedApps.ps1)
Removes provisioned Appx packages from the OS image.

Target: provisioned app display name.

Required fields (per item):
- `name`: display name matched against `Get-AppxProvisionedPackage -Online`.

Behavior:
- Observes provisioned packages once per run.
- If not provisioned, `NOTICE` with `Reason=not_applicable`.
- If provisioned, calls `Remove-AppxProvisionedPackage -Online`.

Example (NOT IMPLEMENTED):
```json
{
  "operation": "remove-provisioned-appx",
  "items": [
    { "name": "Microsoft.BingWeather" }
  ]
}
```

### install-choco-packages (AdminInstallChoco.ps1)
Installs Chocolatey if missing, then installs packages via Chocolatey.

Target: package manager + each package name.

Required fields (entry-level):
- None.

Required fields (per item):
- `name`: package name passed to `choco install`.

Behavior:
- Checks `choco` availability; if missing, installs using the standard bootstrap.
- Packages are installed with `choco install -y`.
- If package already installed, `NOTICE` with `Reason=match`.

Example (NOT IMPLEMENTED):
```json
{
  "operation": "install-choco-packages",
  "items": [
    { "name": "ultravnc" },
    { "name": "chocolateygui" },
    { "name": "7zip" },
    { "name": "adobereader" },
    { "name": "ccleaner" },
    { "name": "choco-cleaner" },
    { "name": "choco-upgrade-all-at" },
    { "name": "firefox" },
    { "name": "ripgrep" },
    { "name": "notepadplusplus" }
  ]
}
```

### install-from-url (shared utility)
Downloads content from a URL and either executes it with arguments or extracts it to a folder.

Target: download/execution or extraction unit.

Required fields (per item):
- `name`: target identifier for logging.
- `url`: source URL.
- `mode`: `execute` or `extract`.
When `mode=execute`, the downloaded content is saved locally and executed; the command does
not need to re-download the URL.

Optional fields (per item):
- `args`: array of arguments passed to the downloaded script when `mode` is `execute`.
- `extractTo`: destination folder when `mode` is `extract`.
- `extractToRelative`: relative folder appended to the resolved host path when `mode` is `extract`.
- `archivePath`: override temp file path (defaults to temp when extracting).
- `scriptPath`: override temp file path (defaults to temp when executing).
- `preFileOps`: optional file batch entries to run before download (uses file schema).
- `postFileOps`: optional file batch entries to run after download (uses file schema).
- `requiresAdmin`: when true, operation requires administrator privileges.
- `hostPaths`: array of candidate host install paths; first existing path is used.
- `outputKey`: optional key used to store runtime output in the output registry (not implemented).
- `commandLine`: explicit command line used when `mode=execute` (for traceability). If set,
  it should execute the downloaded script file, not re-download the URL.

Behavior:
- `execute`: downloads content to a temp file and executes with `args`.
- `extract`: downloads archive to temp and extracts to `extractTo`.
- If `hostPaths` is provided and `extractToRelative` is set, the destination is resolved
  by combining the first existing host path with `extractToRelative`.
- `preFileOps` and `postFileOps` allow reuse of existing file operations as pre/post steps.

Example (execute) (NOT IMPLEMENTED):
```json
{
  "operation": "install-from-url",
  "items": [
    {
      "name": "Chocolatey bootstrap",
      "url": "https://community.chocolatey.org/install.ps1",
      "mode": "execute",
      "args": [ "-NoProfile", "-ExecutionPolicy", "Bypass" ],
      "commandLine": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File <downloaded-script.ps1>"
    }
  ]
}
```

Example (extract) (NOT IMPLEMENTED):
```json
{
  "operation": "install-from-url",
  "items": [
    {
      "name": "ComparePlugin",
      "url": "https://github.com/pnedev/comparePlus/releases/download/v2.0.2/ComparePlugin_v2.0.2_X64.zip",
      "mode": "extract",
      "requiresAdmin": true,
      "hostPaths": [
        "C:\\Program Files\\Notepad++",
        "C:\\Program Files (x86)\\Notepad++"
      ],
      "extractToRelative": "plugins\\ComparePlugin"
    }
  ]
}
```

### install-plugin (AdminInstallNppCompare.ps1)
Use `install-from-url` with `mode=extract` to cover the Notepad++ plugin case.
If host detection is required, keep it in the script layer as a precondition.

### Invalid config patterns (summary)
- Missing required fields per operation.
- `items` is not an array.
- `install-plugin` missing host path candidates or plugin file name.
