# Registry Operations (category: registry)

See also:
- `app/schemas/common.md`

Resolution: see `app/schemas/common.md` for the two-level resolver rules.

Resolution shapes and fields:
- Common/shared resolver: target-only with `key` provided in `context` and `name`/`value`/`type` on each item.

## set-keyvalue
- Required fields: `context.key`, `name`, `value`, `type`.
- Required per item: `name`, `value`, `type`.
- `key` is not allowed at item level; group items by key.
 - Validation hints are domain-specific: `match`/`mismatch` for value comparison and `missing.target` when the value is absent.

Common types: `DWord`, `String`, `QWord`, `Binary`, `MultiString`.

## Category resolution example (context defaults overridden by items)
This shows `context.key` used for all items in the operation.
```json
{
  "operation": "set-keyvalue",
  "context": { "key": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge" },
  "items": [
    { "name": "HideFirstRunExperience", "value": 1, "type": "DWord" }
  ]
}
```

## Invalid config patterns (summary)
- Missing `name`, `value`, or `type` on the item.
- Missing `context.key`.
- Item includes `key` (must be grouped by key at the operation level).


