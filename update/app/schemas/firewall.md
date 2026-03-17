# Firewall Operations (category: firewall_rule)

See also:
- `app/schemas/common.md`

Resolution: see `app/schemas/common.md` for the two-level resolver rules.

Resolution shapes and fields:
- Common/shared resolver: rule `name` plus attributes, with optional `context` defaults (e.g., `direction`, `action`, `profiles`).

## set-firewall-rule
- Required fields: `name`, `direction`, `action`, `protocol`, `profiles`, and `port` when `protocol` is not `ICMP*` or `Any`.
- Required per item: `name`, `protocol`, and `profiles`; `port` is required unless `protocol` is `ICMP*` or `Any`.
- `context` may supply defaults like `direction`, `action`, or `profiles` (no implicit default for `profiles`).

Common attributes: `protocol`, `port`, `direction`, `action`, `profiles`, `program`, `service`.

## Category resolution example (context defaults overridden by items)
This shows `context` defaults for direction/action/profiles and an item override for profiles.
```json
{
  "operation": "set-firewall-rule",
  "context": { "direction": "Inbound", "action": "Allow", "profiles": [ "Private", "Domain" ] },
  "items": [
    { "name": "Allow SSH", "protocol": "TCP", "port": 22 },
    { "name": "Allow RDP", "protocol": "TCP", "port": 3389, "profiles": [ "Private", "Domain", "Public" ] }
  ]
}
```

Example ICMP rule (no port required):
```json
{
  "operation": "set-firewall-rule",
  "context": { "direction": "Inbound", "action": "Allow", "profiles": [ "Private", "Domain", "Public" ] },
  "items": [
    { "name": "Allow ICMP Echo", "protocol": "ICMPv4" }
  ]
}
```

## Invalid config patterns (summary)
- Missing `name` on the item.
- `profiles` is empty or missing and no `context.profiles` is provided (no implicit default).

```json
{
  "operation": "set-firewall-rule",
  "context": { "direction": "Inbound", "action": "Allow", "profiles": [ "Private", "Domain" ] },
  "items": [
    { "name": "Allow SSH", "protocol": "TCP", "port": 22 }
  ]
}
```

