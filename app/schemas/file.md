# File Operations (category: file)

See also:
- `app/schemas/common.md`

Resolution: see `app/schemas/common.md` for the two-level resolver rules.

Resolver layering: see `app/schemas/common.md`. File-specific layer builds target/source paths.

Resolution shapes and fields:
- Common/shared resolver: contains both target-only (`path` or `folder + name`) and source+target (`srcPath` or `srcFolder + srcName` plus target).
- Target-only ops: `remove-file`, `set-acl`.
  - Source+target ops: `copy-file`, `rename-file`, `compress-file`, `expand-archive`, `split-file`, `join-file`.
- Specific resolver: `new-url-shortcut` uses the common target-only resolver plus icon fields.

Notes:
- Source+target operations still use the base target resolver for the target side.
- `new-url-shortcut` uses target-only resolution and adds icon-specific fields.
- `name` represents the target name for `copy-file`, `remove-file`, and `new-url-shortcut`, and the new name for `rename-file`.
- If `folder` is provided without `name` and `srcName` is available, the target name defaults to `srcName`.
- Validation hints are domain-specific: `present.target`/`absent.target` for target existence, `missing.source` for missing inputs, and `missing.icon` for icon checks.
- Invalid definition means required fields are missing or conflicting; it does not depend on filesystem existence.

## Category resolution example (context defaults overridden by items)
This shows `context` defaults for folders/names and item-level overrides for specific files.
```json
{
  "operation": "copy-file",
  "context": { "srcFolder": "C:\\Base", "folder": "C:\\Out", "name": "default.txt" },
  "items": [
    { "srcName": "a.txt" },
    { "srcName": "b.txt", "name": "b-final.txt" },
    { "srcPath": "C:\\Other\\c.txt", "path": "C:\\Out\\c-final.txt", "name": "c-final.txt" }
  ]
}
```

Key sets used by file resolvers:
```json
{
  "target": [ "path", "folder", "name" ],
  "source": [ "srcPath", "srcFolder", "srcName" ]
}
```

## copy-file
- Required fields: `srcPath` or (`srcFolder` + `srcName`), and `path` or (`folder` + `name`).
- Source can be `srcPath` OR `srcFolder + srcName` (or `name` fallback).
- Destination can be `path` OR `folder + name`. If `name` is omitted, it falls back to `srcName`.

```json
{
  "operation": "copy-file",
  "context": { "srcFolder": "..\\data\\resources", "folder": "C:\\Users\\Public\\Desktop" },
  "items": [
    { "srcName": "start2.bin", "name": "start2.bin" },
    { "srcPath": "C:\\Temp\\a.txt", "path": "C:\\Temp\\b.txt", "name": "b.txt" }
  ]
}
```

## remove-file
- Required fields: `path` or (`folder` + `name`).
- `path` OR `folder + name`.

```json
{
  "operation": "remove-file",
  "context": { "folder": "C:\\Users\\Public\\Desktop" },
  "items": [
    { "name": "CCleaner.lnk" },
    { "path": "C:\\Users\\Public\\Desktop\\TeamViewer.lnk", "name": "TeamViewer.lnk" }
  ]
}
```

## rename-file
- Required fields: `srcPath` or (`srcFolder` + `srcName`), and either `path` or `name` (new name).
- Source uses `srcPath` OR `srcFolder + srcName`.
- Destination uses `path` OR (`folder` + `name`). If only `name` is provided, it renames within the source folder.
- If `folder` is provided without `name`, it falls back to `srcName` (effectively a move without renaming).
- `name` is the new filename for this operation.

```json
{
  "operation": "rename-file",
  "context": { "srcFolder": "C:\\Temp", "folder": "C:\\Out" },
  "items": [
    { "srcName": "old.txt", "name": "new.txt" },
    { "srcName": "move.txt", "path": "C:\\Other\\moved.txt", "name": "moved.txt" }
  ]
}
```

## compress-file
- Required fields: `srcPath` or (`srcFolder` + `srcName`), and `name` (archive name) or `path`.
- Source uses `srcPath` OR `srcFolder + srcName`.
- Archive target uses `path` OR `folder + name`.

```json
{
  "operation": "compress-file",
  "context": { "srcFolder": "C:\\Temp", "folder": "C:\\Temp" },
  "items": [
    { "srcName": "report.txt", "name": "report.zip" }
  ]
}
```

## expand-archive
- Required fields: `srcPath` or (`srcFolder` + `srcName`), and destination `folder` (or `path`).
- Archive uses `srcPath` OR `srcFolder + srcName`.
- Destination uses `folder` (or `path` when provided).

```json
{
  "operation": "expand-archive",
  "context": { "folder": "C:\\Temp\\out" },
  "items": [
    { "srcPath": "C:\\Temp\\report.zip" }
  ]
}
```

## set-acl
- Required fields: `path` or (`folder` + `name`), and `accessRules`.
- Target uses `path` OR `folder + name`.

```json
{
  "operation": "set-acl",
  "items": [
    {
      "path": "C:\\Temp\\report.txt",
      "name": "report.txt",
      "accessRules": [
        { "Identity": "Users", "Rights": "ReadAndExecute", "InheritanceFlags": "None", "PropagationFlags": "None", "Type": "Allow" }
      ]
    }
  ]
}
```

## split-file
- Required fields: `srcPath` or (`srcFolder` + `srcName`), `chunkSize`, and destination `folder` or `path`.
- Source uses `srcPath` OR `srcFolder + srcName`.
- Destination uses `folder` (output directory). If `path` is provided, it is treated as the base file path used for chunk naming; its parent directory is the output folder and its file name is the chunk name base.

```json
{
  "operation": "split-file",
  "context": { "folder": "C:\\Temp\\parts" },
  "items": [
    { "srcPath": "C:\\Temp\\big.bin", "chunkSize": 52428800 }
  ]
}
```

Example using `path` as the chunk base name:
```json
{
  "operation": "split-file",
  "items": [
    { "srcPath": "C:\\Temp\\big.bin", "path": "C:\\Temp\\parts\\big.bin", "chunkSize": 52428800 }
  ]
}
```

## join-file
- Required fields: source folder (`srcFolder` or `srcPath`), destination `path` or (`folder` + `name`), and `parts[]`.
- Parts folder uses `srcFolder` (or `srcPath` as the folder path).
- Output uses `path` OR `folder + name`.

```json
{
  "operation": "join-file",
  "context": { "srcFolder": "C:\\Temp\\parts", "folder": "C:\\Temp" },
  "items": [
    { "name": "big.bin", "parts": [ "big.bin.part1", "big.bin.part2" ] }
  ]
}
```

## new-url-shortcut
- Required fields: `folder` + `name` (or `path`), and `url`.
- Target uses `folder + name` (or `path`).
- Icon can be provided via `context.iconPath` or `context.iconFolder + context.iconName`.
 - Resolution note: icon fields follow the same two-level rule (item overrides context) when provided per-item.
 - If an icon path is provided, it must exist (check failure: `missing.icon`).
 - If `name` or `path` omits the `.lnk` extension, it is appended automatically.

## Invalid config patterns (summary)
- `copy-file`: `srcPath` with `srcFolder/srcName` only when they resolve to different source paths (both are allowed when consistent), or `path` with `folder/name`.
- `remove-file`: `path` with `folder/name`.
- `rename-file`: missing `name` and no destination `path`.
- `compress-file`: missing destination `name`/`path`.
- `expand-archive`: missing destination `folder`/`path`.
- `set-acl`: missing or non-list `accessRules`.
- `split-file`: missing `chunkSize` or destination `folder`/`path`.
- `join-file`: missing or empty `parts[]` or missing destination `path`/`folder+name`.
- `new-url-shortcut`: `path` with `folder/name`.
- `copy-file`: target name missing and no `srcName` to fall back on.

