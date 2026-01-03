CONTRACT.md
===========

PURPOSE
-------
This document defines the canonical execution and reporting contract used across all business scripts and utility modules in the project.

The contract defines:
- how a unit of work is classified,
- how its final state is expressed,
- how results are aggregated,
- how execution outcomes are made observable.

The contract is technology-agnostic and applies identically to:
- files
- registry
- firewall rules
- services
- users
- devices
- configuration rules
- scripts (orchestrators)

Any deviation from this contract is considered a defect.

DEFINITIONS
-----------
TARGET
~~~~~~
A TARGET is a unit of work whose lifecycle is observable and meaningful at the abstraction level of the component emitting the result.

Examples:
- script
- declarative configuration rule
- file
- registry key or value
- firewall rule
- service
- user
- device

A TARGET must have:
- a clear scope,
- a single final observable state.

EVALUATION
~~~~~~~~~~
Evaluation means verifying or comparing the current state of a TARGET against its desired state.

Evaluation includes:
- existence checks
- reads
- comparisons
- compliance verification

Evaluation does NOT imply modification.

ACTION
~~~~~~
Action means attempting to change the state of a TARGET.

Action includes:
- create
- update
- delete
- remove
- apply
- enforce

An action may succeed or fail.

CONTRACT STRUCTURE
------------------
Every TARGET execution MUST return a result object with the following fields:

{ Observed, Applied, Changed, Failed, Skipped }

All fields are integer counters (0 or 1 for a single TARGET).

FIELD SEMANTICS
---------------
Observed
~~~~~~~~
Definition:
- Indicates whether the TARGET was observed.

Rules:
- Observed = 1 if the state of the TARGET was verified or compared.
- Observed = 0 if no observation occurred.

Notes:
- Reading state counts as observation.
- Observation does not imply action.

Applied
~~~~~~
Definition:
- Indicates whether an action was attempted on the TARGET.

Rules:
- Applied = 1 if an action was executed or attempted.
- Applied = 0 if no action was attempted.

Notes:
- A successful or failed action both count as Applied.
- Applied MAY occur with or without prior observation.

Changed
~~~~~~
Definition:
- Indicates whether the TARGET state was successfully modified.

Rules:
- Changed = 1 if the desired state was applied successfully.
- Changed = 0 otherwise.

Notes:
- Changed implies Applied.
- Changed implies Observed.

Failed
~~~~~~
Definition:
- Indicates that the TARGET failed to reach a valid final state.

Rules:
- Failed = 1 if an attempted action failed or the contract could not be fulfilled.
- Failed = 0 otherwise.

Notes:
- Failed implies Applied.
- Failed implies Observed (at least post-action).

Skipped
~~~~~~
Definition:
- Indicates that the TARGET was intentionally not acted upon.

Rules:
- Skipped = 1 if the TARGET was deliberately ignored or deferred.
- Skipped = 0 otherwise.

Notes:
- Skipped expresses an execution decision, not a lack of observation.
- Skipped MUST imply Applied = 0.
- Skipped MAY occur with or without observation.

INTENT METADATA (REQUIRED)
-------------------------
Implementations MUST attach a non-aggregated `Reason` field to each TARGET result.

The `Reason` field expresses the intent or cause of the final observable state without altering
the canonical contract counters.

Rules:
- `Reason` MUST NOT affect Observed, Applied, Changed, Failed, or Skipped.
- `Reason` MUST NOT be used for aggregation.
- `Reason` MUST NOT influence exit codes.
- Absence of `Reason` is a contract defect.

The `Reason` field exists to disambiguate situations that share the same final state but differ
in intent or applicability.
`Reason` captures categorical intent; detailed diagnostics belong in DEBUG logs (see `LOGGING.md` → DEBUG).

Typical values (non-exhaustive):
- match
- mismatch
- missing
- present
- not_applicable
- condition_mismatch
- not_due
- dependency_missing
- invalid_definition
- exception
- policy
- aggregate

Phase helpers MAY emit `Reason` tokens in the form `<phase>.<outcome>` (e.g., `preverify.ok`, `check.fail`,
`run.fail`, `verify.ok`) with optional `Hint` and detail appended as ` | <hint> | <detail>`, provided they do not
contradict the contract counters.

Reason values MUST be orthogonal to contract counters. They describe why the final state occurred, not the final state itself.

Implementations MAY use additional project-specific `Reason` values as long as they do not contradict the contract counters.

The `Reason` field MUST NOT contradict the contract counters.



CANONICAL STATE MATRIX
---------------------
| Situation                                    | Observed | Applied | Changed | Failed | Skipped |
|---------------------------------------------|----------|---------|---------|--------|---------|
| Invalid definition (not evaluable)           | 0        | 0       | 0       | 0      | 1       | (Reason: invalid_definition)
| Non-applicable after evaluation              | 1        | 0       | 0       | 0      | 1       | (Reason: not_applicable)
| Not due (scheduler decision)                 | 1        | 0       | 0       | 0      | 1       | (Reason: not_due)
| Object absent, absence verified              | 1        | 0       | 0       | 0      | 0       |
| Object present and compliant                 | 1        | 0       | 0       | 0      | 0       |
| Object modified successfully                 | 1        | 1       | 1       | 0      | 0       |
| Action attempted but failed                  | 1        | 1       | 0       | 1      | 0       |

AGGREGATION RULES
-----------------
When aggregating multiple TARGET results:
- All fields are summed.
- Aggregation is strictly additive.
- No derived fields are allowed.
- Per-TARGET results MUST be preserved alongside aggregates for audit and traceability.

Aggregated results MUST preserve the same field semantics.

LOGGING RELATION
----------------
The contract is orthogonal to logging semantics: contract counters must not be inferred from logs, and logs must not redefine contract meaning.

Canonical logging rules (levels, per-TARGET logs, summaries) are defined in `LOGGING.md`.
This contract only defines the meaning of the counters and the required `Reason` intent metadata (categorical intent).

EXIT CODES
----------
For scripts acting as orchestrators:
- Exit 0 if Failed = 0 for all TARGETS.
- Exit 1 if Failed > 0 for any TARGET.

Exit codes reflect contract fulfillment only.

INVARIANTS
----------
Contract invariants are the source of truth for contract behavior. Logging invariants are defined in `LOGGING.md` → INVARIANTS.

- Every TARGET ends in exactly one final observable state.
- Observation and action are orthogonal.
- Changed implies Applied and Observed.
- Failed implies Applied and Observed.
- Skipped implies Applied = 0.
- Contract semantics are identical across all domains.
- No implementation detail may affect contract meaning.

SCOPE
-----
This contract applies to:
- business scripts
- batch operations
- utility modules
- orchestration layers

Any extension of the contract MUST preserve all invariants above.

END OF CONTRACT

TODO / NOT IMPLEMENTED
----------------------
- Output registry and interpolation: documented only; not implemented in runtime.
- Unified batchOperations merge: schema documented; runtime dispatcher not implemented.

Output registry (optional; not implemented)
Implementations MAY maintain an in-memory output registry for reuse within the same batch list.
The registry may store data under a caller-provided `outputKey` for later interpolation.
Output data shape is implementation-defined and not specified until the feature is implemented.


OUTPUT REGISTRY (OPTIONAL)
--------------------------
Implementations MAY maintain an in-memory output registry for reuse within the same batch list.

Rules:
- The registry is scoped to the current batch list only.
- Later steps may reference prior outputs; forward references are invalid.
- References are string substitutions only.

Simple registry form (recommended):
```
OutputKey = "download"
OutputValue = { path: "C:\\Temp\\file.zip", size: 1234, hash: "..." }
```

Interpolation format (recommended):
```
${download.path}
```

If multiple outputs exist, use unique `OutputKey` values to avoid collisions.
