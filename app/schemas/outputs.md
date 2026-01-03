# Output Registry (optional)
This document defines an optional output registry for reuse within a batch list.

See also:
- `app/CONTRACT.md`
- `app/schemas/common.md`

## Concept
Operations may emit output data. When an item specifies an `outputKey`, the
runner stores that output data in a registry keyed by `outputKey`.

Example output registration (NOT IMPLEMENTED):
```json
{
  "operation": "install-from-url",
  "items": [
    { "name": "ExampleDownload", "outputKey": "download" }
  ]
}
```

Example output stored under `download` (NOT IMPLEMENTED):
```json
{
  "path": "C:\\Temp\\ComparePlugin.zip",
  "size": 123456,
  "hash": "sha256:..."
}
```

## Interpolation
Later items may reference prior outputs using `${key.path}` syntax.

Example (NOT IMPLEMENTED):
```json
{
  "operation": "remove-file",
  "items": [
    { "path": "${download.path}" }
  ]
}
```

Rules:
- Scope is limited to the current batch list.
- Only backward references are allowed.
- Substitution is string-based; missing keys are invalid definitions.
