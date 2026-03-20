SPEC.md
=======

PURPOSE
-------
This document defines the Universal Intent Contract (UIC), a companion specification
to the execution and reporting contract defined in `app/CONTRACT.md`.

UIC formalizes how an operator declares intent, preferences, and policy decisions
BEFORE convergence runs — so that convergence functions are deterministic, non-interactive,
and never make consequential choices silently.

UIC is an INPUT contract. The execution contract (`app/CONTRACT.md`) is an EXECUTION contract.
They are orthogonal and complementary. UIC does not replace or extend CONTRACT.md.

Any deviation from this specification is considered a defect.


SCOPE OF PROBLEMS RESOLVED
---------------------------
UIC resolves problems that are outside the scope of the execution contract:

1. Multiple valid transition paths
   The execution contract defines HOW to converge. It does not choose between
   two valid paths to the same desired state (e.g., adopt vs. reinstall).
   UIC declares which path the operator has chosen and why.

2. Destructive action authorization
   The execution contract applies transitions without regard to reversibility.
   UIC declares explicit operator sign-off before a destructive or irreversible
   action may proceed.

3. Pre-flight gates
   The execution contract begins at observation. It does not define conditions
   that must be true before convergence may safely start.
   UIC declares pre-conditions that block convergence if not satisfied.

4. Cross-component policy consistency
   The execution contract is scoped to a single TARGET. It cannot enforce
   a preference across multiple components (e.g., "prefer package-manager-owned
   for all installed applications").
   UIC declares global policies that apply uniformly across components.

5. Context-sensitive defaults
   The execution contract does not distinguish a fresh environment from an
   existing one. UIC declares how operator intent differs by context.

6. Bootstrap ambiguity
   The execution contract assumes the execution context already exists.
   UIC declares what must be true before convergence may begin.


RELATIONSHIP TO THE EXECUTION CONTRACT
---------------------------------------

  Operator
     │
     ▼
  [ UIC ]   — declares intent, resolves ambiguity, gates destructive actions
     │
     ▼
  [ Execution contract ]   — observes, diffs, converges
     │
     ▼
  System

UIC is resolved once, before convergence begins.
The execution contract reads the resolved UIC context; it does not modify it.
UIC results are not aggregated into execution contract counters.


DEFINITIONS
-----------

INTENT
~~~~~~
An INTENT is an operator declaration that governs HOW a transition is performed,
not WHAT the desired state is.

An INTENT has:
- a name (unique within scope),
- a value (the chosen option),
- a scope (global or component-specific),
- a rationale (why this option was chosen — required).

Example:
  INTENT docker.install_method = adopt
  Rationale: Application already present at expected path; re-download unnecessary.

POLICY
~~~~~~
A POLICY is a rule derived from one or more INTENTs that constrains which
transition functions are permissible for a given TARGET.

A POLICY is evaluated before the transition function is selected.
A POLICY violation blocks execution with outcome=skipped, reason=policy.

Example:
  POLICY: if install_method = package-manager, then observe must use
          package-manager presence check, not filesystem presence check.

GATE
~~~~
A GATE is a pre-condition that must be satisfied before convergence may proceed.
A GATE is evaluated before observation begins.

A GATE has:
- a condition (evaluable without side effects),
- a scope (global or component-specific),
- a blocking level: hard (abort) or soft (warn and skip component).

A failed hard GATE produces outcome=failed, reason=gate_failed for all
dependent TARGETs without observation or transition.

A failed soft GATE produces outcome=skipped, reason=gate_not_satisfied for
all dependent TARGETs without observation or transition.

Example:
  GATE: Docker settings file must exist before docker-resources TARGET runs.
  Blocking level: soft.
  On failure: skip docker-resources with reason=gate_not_satisfied.

AMBIGUITY
~~~~~~~~~
An AMBIGUITY is a situation where multiple valid transition paths exist for a
TARGET and no INTENT has declared a preference.

An unresolved AMBIGUITY detected at pre-flight MUST surface as a diagnostic.
An unresolved AMBIGUITY encountered at convergence time MUST produce
outcome=skipped, reason=ambiguity_unresolved.

Implementations MUST NOT silently choose a path when an AMBIGUITY exists.


CONTRACT STRUCTURE
------------------
A UIC declaration consists of three sections:

1. GATES      — pre-conditions evaluated before convergence starts
2. INTENTS    — operator preferences that resolve ambiguous transitions
3. POLICIES   — rules derived from intents, applied at transition selection time

All three sections are optional. An empty UIC declaration is valid and means:
"no gates, no declared intents, no policies — proceed with implementation defaults."


GATE CONTRACT
-------------
A GATE result MUST express:
- gate name
- condition evaluated
- outcome: satisfied | not_satisfied
- blocking level: hard | soft
- reason (if not_satisfied): free text, mandatory

A GATE result MUST NOT contribute to execution contract counters.
GATE evaluation is pre-convergence; it precedes TARGET observation.

A hard GATE failure MUST abort all dependent TARGETs.
A soft GATE failure MUST skip all dependent TARGETs with reason=gate_not_satisfied.


INTENT CONTRACT
---------------
An INTENT declaration MUST express:
- intent name (unique, namespaced by component if scoped)
- chosen value
- available options (non-empty, at least two)
- rationale (mandatory — absence is a contract defect)

An INTENT with only one available option is not an INTENT; it is a constant.
Constants belong in component configuration, not in UIC declarations.

An INTENT MUST be declared before convergence begins.
An INTENT MUST NOT be modified during convergence.

An undeclared INTENT encountered during convergence MUST produce
outcome=skipped, reason=ambiguity_unresolved for the affected TARGET.


POLICY CONTRACT
---------------
A POLICY is derived from INTENTs. It MUST NOT introduce new preferences
not already expressed by a declared INTENT.

A POLICY applies to a named TARGET or a named component (all TARGETs within it).

A POLICY violation MUST produce outcome=skipped, reason=policy for the
affected TARGET. It MUST NOT produce outcome=failed.

A POLICY violation is not an error. It is an execution decision: the operator's
declared intent makes the default transition path non-applicable.


RESOLUTION ORDER
----------------
Before convergence begins, implementations MUST resolve in this order:

1. Evaluate all hard GATEs. Abort if any fails.
2. Evaluate all soft GATEs. Record failures; affected TARGETs will be skipped.
3. Load all INTENT declarations. Fail if any required INTENT is undeclared.
4. Derive POLICIES from INTENTs.
5. Begin convergence (execution contract).

This order is normative. Any deviation is a defect.


PRE-FLIGHT MODE
---------------
Implementations SHOULD support a pre-flight mode that:
- evaluates all GATEs,
- detects all AMBIGUITIES (TARGETs whose transition depends on an undeclared INTENT),
- reports required INTENTs with their available options,
- does NOT begin convergence.

Pre-flight mode is read-only. It MUST NOT modify system state.

Pre-flight output format (recommended):

  [GATE]    <gate-name> : <satisfied|not_satisfied> [hard|soft]
  [INTENT]  <intent-name> : undeclared — options: <opt1> | <opt2> | ...
  [POLICY]  <policy-name> : <applicable|not_applicable>

Pre-flight exit codes:
- Exit 0 if all GATEs are satisfied and no AMBIGUITIEs are unresolved.
- Exit 1 if any hard GATE fails or any required INTENT is undeclared.
- Exit 2 if only soft GATEs fail or only optional INTENTs are undeclared.


INVARIANTS
----------
- UIC is resolved before convergence begins. Never during.
- INTENTs declare operator preference. They do not declare desired state.
- GATEs block convergence. They do not substitute for observation.
- An unresolved AMBIGUITY produces skipped, not failed.
- A POLICY violation produces skipped, not failed.
- A hard GATE failure produces failed for all dependent TARGETs.
- UIC results are never aggregated into execution contract counters.
- Rationale is mandatory for every INTENT declaration.
- An INTENT with one option is a defect.
- UIC does not define what the desired state is. That remains the execution contract's domain.


SCOPE
-----
This specification applies to any implementation that:
- uses the execution contract defined in `app/CONTRACT.md`,
- encounters TARGETs with multiple valid transition paths,
- requires pre-flight gate evaluation,
- requires explicit operator authorization for destructive transitions.

Implementations that have no ambiguous transitions and no pre-flight gates
MAY omit UIC entirely. Omission is not a defect.


END OF SPEC
