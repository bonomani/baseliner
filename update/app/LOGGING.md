LOGGING.md

PURPOSE
-------

This document defines the canonical logging rules used across the entire project.

The objective of logging is to make TARGET execution observable: `INFO` answers WHAT is being processed; `NOTICE` answers the FINAL OBSERVABLE STATE; `DEBUG` may provide optional explanation/diagnostics (see `CONTRACT.md` → LOGGING RELATION).

Any log entry that does not contribute to one of these objectives is considered invalid.

CONTRACT BOUNDARY
-----------------
Logging is orthogonal to contract semantics; see `CONTRACT.md` → LOGGING RELATION.


MODEL
-----

Logging describes the lifecycle of a TARGET.

A TARGET is a unit of work whose lifecycle is observable, stable, and meaningful
at the abstraction level of the component emitting the log.

IMPORTANT:
The definition of a TARGET depends on the abstraction level of the component.

- In an orchestrator, the TARGET is a script.
- In a business script, the TARGET is a domain entity OR a declarative rule
  explicitly defined in configuration.
- In a module or utility layer, there is typically no TARGET; logs are implementation-only. If a module does emit TARGET-level logs, it must follow the same INFO/NOTICE semantics.

A declarative rule is a valid TARGET if and only if:
- it is explicitly defined in configuration,
- it is processed as a single unit of work,
- it has a final observable state.

Examples of targets (non-exhaustive):
- script
- configuration rule
- file
- folder
- registry key
- drive
- application
- user
- device
- record
- task
- job
- configuration entry

All logging rules apply identically, regardless of script type or technology.


LOG LEVELS
----------

INFO — Target Taken in Charge

Meaning:
- Declares that a TARGET is being processed.
- Emitted once per TARGET.
- Never expresses a result or outcome.

Answers:
What is being processed?

Examples:
INFO  Executing script UserMapDrives.ps1
INFO  Processing startup rule OneDrive*
INFO  Processing drive H
INFO  Processing application Microsoft Edge
INFO  Processing file Adobe Acrobat.lnk
INFO  Processing user pc31\bc


NOTICE — Observable Final State

Meaning:
- Declares the final observable state of a TARGET.
- Emitted after processing (exactly once per TARGET).
- Covers both changed and unchanged states.
- When a component emits contract counters, the final `NOTICE` for a TARGET SHOULD include `Observed, Applied, Changed, Failed, Skipped` (see `CONTRACT.md` → CONTRACT STRUCTURE).
- The final `NOTICE` for a TARGET MUST be contract-compliant (see `CONTRACT.md` → INTENT METADATA).

Answers:
What is the final state?

Recommended format:
NOTICE <TargetType> <TargetId> <final state> [| Observed=… Applied=… Changed=… Failed=… Skipped=…]

Examples:
NOTICE Script UserMapDrives completed | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=drives
NOTICE Startup rule OneDrive* applied (disabled=2, unchanged=1)
NOTICE Startup rule CCleaner* had no matching entries
NOTICE Drive H mapped to \\server\\share
NOTICE Drive H already correctly mapped
NOTICE Application Outlook unpinned
NOTICE Application Outlook already absent from taskbar
NOTICE File Adobe Acrobat.lnk removed
NOTICE File Adobe Acrobat.lnk already absent
NOTICE Drive H mapped to \\server\\share | Observed=1 Applied=1 Changed=1 Failed=0 Skipped=0

NOTICE logs must be meaningful when read alone.

Helpers such as `Invoke-CheckDoReportPhase` return counters + `Reason` but do not emit the final `NOTICE`. Callers
MUST log the final per-TARGET `NOTICE` with counters + `Reason` to satisfy this contract.


DEBUG — Explanation

Meaning:
- Provides diagnostics/explanation for a given final state.
- Contains implementation details, decisions, or diagnostics.
- Must directly support understanding the final observable state (otherwise invalid).
- Must never be required to understand the final outcome.

Answers:
What diagnostics explain this result?
DEBUG answers diagnostic why (implementation/evidence). For categorical intent (e.g., not_applicable, dependency_missing), use the contract `Reason` field; see `CONTRACT.md` → INTENT METADATA.

Phase helpers MAY emit `Reason=<phase>.<outcome>` (e.g., `preverify.ok`, `check.fail`, `run.fail`, `verify.ok`)
with optional `Hint` and detail after ` | ` when appropriate (e.g., `Reason=check.fail | missing.source | path`).

Examples:
DEBUG Matched entries: OneDrive, OneDriveSetup
DEBUG Server not reachable
DEBUG Shortcut not found in filesystem
DEBUG Verify phase already satisfied
DEBUG Backup server selected


WARN — Degraded Result

Meaning:
- The TARGET was processed, but the result is degraded or abnormal.
- The script continues execution.
- `WARN` does not define contract outcome; contract outcome is expressed only via contract counters (see `CONTRACT.md` → invariants/exit codes).
- A `WARN` may accompany either an overall success or failure, depending on the contract counters.

Examples:
WARN Startup rule EdgeAutoLaunch* partially applied (1 failed)
WARN Drive H skipped: no server reachable
WARN Application Edge could not be unpinned (access denied)


ERROR — Blocking Failure

Meaning:
- A blocking failure occurred.
- `ERROR` indicates a blocking failure; contract outcome is expressed only via contract counters (see `CONTRACT.md` → exit codes).
- Typically followed by process termination.

Examples:
ERROR Failed to load configuration file
ERROR Unable to write output file


SUMMARY LOGS
------------

- Summary logs use NOTICE only.
- They are aggregated and non-redundant.
- They describe the global outcome of the execution.
- Summary logs never replace per-TARGET logs.

Example:
NOTICE Finished:
- Scripts: executed=5, failed=0
- Startup rules: processed=3, applied=1, unchanged=2, failed=0
- Drives: processed=2, mapped=1, unchanged=1, failed=0
- Applications: processed=9, changed=0, unchanged=9
- Files: processed=3, removed=0, unchanged=3


INVARIANTS
----------

- INFO answers: what is being processed
- NOTICE answers: what is the final observable state
- DEBUG answers: optional explanation/diagnostics
- WARN signals a degraded but non-fatal result
- ERROR signals a blocking failure
- Orchestrators log scripts as TARGETS
- Business scripts log domain entities or declarative rules as TARGETS
- Modules typically do not define TARGETS; if they do, they follow the same INFO/NOTICE semantics
- Orchestrators SHOULD emit one INFO per child script TARGET even if the child script also logs its own INFO
- Orchestrators SHOULD NOT emit per-child NOTICE when the child script already emits a final NOTICE for its own TARGET
- INFO/NOTICE logs never depend on implementation details

LOGGING CHECKLIST
-----------------
Use this checklist to keep wording and structure consistent.

- INFO must declare the TARGET being processed (no outcome).
- NOTICE must declare the final observable state and include counters when applicable.
- Use explicit target type + identifier in both INFO and NOTICE.
- Use action verbs in INFO that match the domain (Set, Apply, Remove, Create, Invoke, etc.).
- When a target is already correct, prefer “already compliant” phrasing.

Explicit wording examples:
- Script target:
  - INFO  Start script 'AdminScheduleAdminTasks'.
  - NOTICE End script 'AdminScheduleAdminTasks' | Reason=aggregate | observed=1 applied=1 changed=0 failed=0 skipped=0 | scope=tasks
- Task target:
  - INFO  Set scheduled task 'UbiRegularAdminTasks'.
  - NOTICE Scheduled task already compliant: 'UbiRegularAdminTasks' | Reason=match | observed=1 applied=0 changed=0 failed=0 skipped=0
- File target:
  - INFO  Remove file 'Adobe Acrobat.lnk' from 'C:\Users\Public\Desktop'.
  - NOTICE File 'Adobe Acrobat.lnk' already absent from 'C:\Users\Public\Desktop'. | Reason=missing
- Registry target:
  - INFO  Set registry value 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OOBE\DisablePrivacyExperience'.
  - NOTICE Registry value already compliant: 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OOBE\DisablePrivacyExperience' | Reason=match
- Firewall rule target:
  - INFO  Set firewall rule 'Allow RDP'.
  - NOTICE Firewall rule already compliant | Reason=match
- Package target:
  - INFO  Install package 'firefox'.
  - NOTICE Package 'firefox' already installed | Reason=match

LOG STYLE (TARGET LOGS)
-----------------------
These rules apply to TARGET-level logs (INFO/NOTICE). Violations are defects.

- Messages are short and specific; one sentence, active voice.
- Include the TARGET type and identifier (example: `file 'C:\Path\File'`, `task 'Name'`).
- Use consistent path quoting (`'C:\Path\To\File'`).
- Avoid payload dumps; log counts and key identifiers only.
- Parent/child wording must be distinct (parent=orchestrator, child=script).
- Script lifecycle markers (start/end) are allowed and are not subject to TARGET verb guidance.

VERB GUIDANCE
-------------
Use precise, action-specific verbs. Prefer the verb that reflects the operation being applied.

TARGET verbs (examples):
- Set (registry values, firewall rules, network profiles, permissions)
- Apply (policy/layout/profile templates)
- Install (packages, plugins)
- Remove (uninstall, delete, unpin)
- Copy (file copy)
- Create (shortcuts, new artifacts)
- Extract (archive extraction)
- Compress (archive creation)
- Map (drive mappings)
- Disable (startup/task disable)
- Rename (rename operations)
- Update (counters/records)
- Split (file splitting)
- Join (file joining)
- Compare (read-only checks)

ORCHESTRATOR verbs (examples):
- Invoke (child scripts)

DEBUG STYLE (NON-TARGET LOGS)
----------------------------
These rules apply to DEBUG logs that are not TARGET-level. Violations are defects.

- DEBUG must add information not already present in INFO/NOTICE (evidence, mismatch, skip reason, or exception context).
- Avoid payload dumps; log counts and key identifiers only.
- INFO/NOTICE logs never depend on implementation details
- The same logging semantics apply everywhere

Any deviation from these invariants is considered a defect.


