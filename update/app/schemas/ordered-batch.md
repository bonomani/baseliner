# Ordered Batch Operations (global sequence)
This document defines a global, ordered batch sequence that can mix categories
(file, registry, firewall, app/package, plugins) in a single list.

Qualified operation names (for example, `file.copy-file`) are part of this NOT IMPLEMENTED flow.

See also:
- `app/schemas/common.md`
- `app/schemas/file.md`
- `app/schemas/registry.md`
- `app/schemas/firewall.md`

## Envelope (NOT IMPLEMENTED)
Use a single ordered list of batch entries. You can optionally wrap the list with
a name for namespacing.

Array form (NOT IMPLEMENTED):

```json
{
  "batchOperations": [
    {
      "operation": "file.copy-file",
      "context": { "srcFolder": "C:\\Base", "folder": "C:\\Out" },
      "items": [ { "srcName": "a.txt", "name": "a.txt" } ]
    },
    {
      "operation": "registry.set-keyvalue",
      "context": { "key": "HKLM:\\SOFTWARE\\Policies\\Vendor" },
      "items": [ { "name": "Setting", "value": 1, "type": "DWord" } ]
    },
    {
      "operation": "firewall.set-firewall-rule",
      "context": { "direction": "Inbound", "action": "Allow", "profiles": [ "Domain" ] },
      "items": [ { "name": "Allow SSH", "protocol": "TCP", "port": 22 } ]
    }
  ]
}
```

Named wrapper form (NOT IMPLEMENTED):
```json
{
  "batchOperations": {
    "name": "admin-baseline",
    "entries": [
      {
        "operation": "file.copy-file",
        "context": { "srcFolder": "C:\\Base", "folder": "C:\\Out" },
        "items": [ { "name": "a.txt", "srcName": "a.txt" } ]
      }
    ]
  }
}
```

## Required fields (NOT IMPLEMENTED)
- `batchOperations`: array or object with `{ name, entries }`; order is preserved.
- Each entry must include:
  - `operation`: qualified handler name (e.g., `file.copy-file`, `registry.set-keyvalue`).
  - `items`: array of concrete items (targets) in the desired order.
  - `context`: optional defaults shared by the entry's items.

## Ordering rules (NOT IMPLEMENTED)
- Entries are executed in the order they appear in `batchOperations`.
- Items are executed in the order they appear in each entry's `items` array.
- JSON objects (maps) do not guarantee order and must not be used for `batchOperations` or `items` when ordering matters.
When using the named wrapper form, order is defined by `entries`.

## Category routing (NOT IMPLEMENTED)
Dispatch is based on the `operation` prefix:
- `file.*`: use file batch dispatcher + handlers (`app/lib/FileOperationUtils.psm1`).
- `registry.*`: use registry batch dispatcher + handlers (`app/lib/RegistryOperationUtils.psm1`).
- `firewall.*`: use firewall batch dispatcher + handlers (`app/lib/FirewallRuleOperationUtils.psm1`).
- `app.*` / `plugin.*`: define a category-specific dispatcher (not yet implemented).

## Invalid config patterns (summary) (NOT IMPLEMENTED)
- Missing `operation` or `items`.
- `items` is not an array.
- `operation` prefix not recognized by the dispatcher.
