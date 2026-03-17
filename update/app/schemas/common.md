# Common Schema
This document defines common structure and resolution rules for mutable operations across file, registry, and firewall categories.

See also:
- `app/schemas/file.md`
- `app/schemas/registry.md`
- `app/schemas/firewall.md`

## Common envelope
Every mutable batch uses the same outer shape:

```json
{
  "operation": "<operation-name>",
  "context": { },
  "items": [ { } ]
}
```

- `operation`: handler name (e.g., `copy-file`, `set-keyvalue`).
- `context`: optional defaults shared by all `items`. When `context.name` is present, it is used
  as the namespace prefix for outputs produced by this entry.
- `items`: list of concrete items (targets) for the operation.

When both an item field and a context field exist, the item field wins.
This rule applies to any category (file, registry, firewall).

Each item should generally include a `name` to make targets identifiable in logs and reviews (even when `path` is used).

## Ordering
Batch execution order is defined by array order in configuration:

- `items` must be a JSON array to guarantee per-item order.
- Multiple batch entries (for example, in `fileBatchOperations`, `registryBatchOperations`, or `firewallBatchOperations`) are executed in the order they appear in their arrays.
- JSON objects (maps) do not guarantee ordering and must not be used for `items` when ordering matters.

## Resolution rules (two-level resolver)
Each item is resolved using two levels:

1) Item fields (per-target)
2) Context defaults (shared)

Resolution process:
1) Start with the item as the primary source of truth.
2) If a required field is missing on the item, fall back to `context`.
3) Category-specific resolvers define how fields are combined (e.g., direct vs grouped fields).

Notes:
- Categories may introduce their own field names (e.g., registry uses `key` defaults; firewall uses `profiles` defaults).
- Item-over-context precedence still applies to those category-specific fields.

Resolver layering:
- Common resolver (all categories): resolves item vs context precedence for arbitrary fields.
- Category resolvers: combine fields according to category rules (e.g., file target/source resolution).
- Operation resolvers: add operation-specific fields (e.g., icons for new-url-shortcut).

Implementation note:
- `Resolve-Item` only applies item vs context precedence for the provided fields; it does not combine fields.

## Invalid config patterns (general)
- Required fields missing at both item and context level.
- Item values that are structurally incompatible with the operation shape (wrong type or missing key fields).
- Conflicting values that the resolver cannot reconcile (category-specific; see per-category schema).


Output registry (optional)
If a batch runner implements the output registry (see `CONTRACT.md`), items MAY reference
prior outputs using the `${key.path}` form (for example, `${download.path}`).
