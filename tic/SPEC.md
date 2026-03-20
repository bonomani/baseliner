# SPEC.md

TIC - Test Intent Contract
==========================

PURPOSE
-------
This document defines the Test Intent Contract (TIC), a generic testing framework
for describing how tests are specified, structured, executed, and reported.

TIC is framework-neutral. It does not define product behavior, runtime semantics,
or convergence rules. It defines how tests should be expressed for any kind of
codebase.

TIC is designed to complement:

- UIC: pre-flight intent, gates, ambiguity, and operator decisions
- UCC: execution, convergence, and runtime result semantics

TIC does not replace either framework.

REPO-DERIVED PRINCIPLES
-----------------------
The following implementation ideas are taken from the Baseliner contract and
logging model because they make tests sharper and easier to verify:

- Every test target SHOULD end in one clear final observable state.
- Test results SHOULD distinguish observation from action.
- A test oracle SHOULD be explicit and not inferred from incidental output.
- Reporting SHOULD include a final outcome plus a short reason or diagnostic.
- Aggregated summaries MUST preserve the per-test result behind them.
- A test SHOULD be deterministic and repeatable.
- When a test is not applicable, the skip reason SHOULD be explicit.
- Test logs SHOULD answer what is being tested, what the final state is, and
  why the result is what it is.


SCOPE
-----
TIC covers:

1. Test declaration
   How a test is named, scoped, and described.

2. Test structure
   How setup, stimulus, observation, and assertions are organized.

3. Test intent
   How the purpose of the test is stated before implementation details.

4. Test oracles
   How expected outcomes are defined in a verifiable way.

5. Test execution
   How a test run is started, isolated, repeated, and compared.

6. Test reporting
   How a test communicates pass, fail, skip, and diagnostic output.

7. Test traceability
   How a test links back to a requirement, intent, or contract rule.

TIC intentionally does not prescribe language-specific tooling, file formats,
or assertion libraries.


RELATIONSHIP TO UIC AND UCC
---------------------------

  Intent / Policy
        │
        ▼
      [ UIC ]   - pre-flight gates, ambiguities, operator choices
        │
        ▼
      [ UCC ]   - execution and convergence behavior
        │
        ▼
      [ TIC ]   - how tests are described and evaluated
        │
        ▼
      Test Runner / Harness

UIC and UCC describe what the system may do.
TIC describes how we verify that behavior.

TIC may reference UIC and UCC requirements as test targets, but it MUST NOT
change their semantics.


DEFINITIONS
-----------

TEST INTENT
~~~~~~~~~~~
A TEST INTENT is a concise statement of what the test is meant to prove.

It should answer:
- what behavior is being verified,
- why the behavior matters,
- what must remain true if the test passes.

Example:
  Test Intent: verify that a missing required input causes a pre-flight failure.

SCENARIO
~~~~~~~~
A SCENARIO is a test case expressed as a self-contained path from setup to result.

A scenario SHOULD contain:
- a setup phase,
- a stimulus/action,
- an observation phase,
- an expected outcome.

ORACLE
~~~~~~
An ORACLE is the rule used to decide whether the observed result is correct.

An oracle MAY be:
- explicit expected values,
- structural expectations,
- invariant checks,
- state comparisons,
- diagnostic pattern checks.

FIXTURE
~~~~~~~
A FIXTURE is any controlled test input or environment preparation used to make
the scenario reproducible.

Fixture examples:
- config files,
- mock data,
- temp folders,
- seeded state,
- stubbed services.

HARNESS
~~~~~~~
A HARNESS is the execution machinery that runs tests, captures output, and
returns standardized results.

A harness SHOULD isolate tests when possible and MUST report failures in a way
that is attributable to a single scenario.

TRACEABILITY
~~~~~~~~~~~~
Traceability is the ability to link a test back to the rule, requirement, or
contract it validates.

Every non-trivial test SHOULD declare one or more trace targets.


TEST CONTRACT STRUCTURE
-----------------------
A TIC-compliant test declaration SHOULD express:

1. Name
2. Intent
3. Scope
4. Preconditions
5. Setup / Fixtures
6. Action
7. Expected observations
8. Oracle
9. Cleanup
10. Trace targets

These fields may be represented in code, markdown, JSON, YAML, or another format,
as long as the information is explicit and machine-checkable where practical.


TEST PHASES
-----------
TIC recommends the following phases:

1. Discover
   Find applicable tests and determine scope.

2. Arrange
   Build fixtures and prepare the environment.

3. Act
   Execute the code path or workflow under test.

4. Observe
   Capture outputs, state changes, logs, and diagnostics.

5. Assert
   Compare observed results to the oracle.

6. Cleanup
   Restore the environment and dispose of fixtures.

7. Report
   Emit the final test status and any diagnostics.

The phases are normative in meaning, but implementations may map them to local
tooling as needed.

OBSERVATION / ACTION RULE
-------------------------
Tests SHOULD keep observation and action separate whenever possible.

If a test mutates state, it SHOULD still observe the final state explicitly.
If a test only observes state, it SHOULD report that no action was attempted.

This mirrors the Baseliner contract rule that observation and action are
orthogonal, and that final state must be explicit.


QUALITY RULES
-------------
- A test SHOULD verify one primary behavior.
- A test SHOULD be deterministic.
- A test SHOULD be repeatable.
- A test SHOULD minimize hidden dependencies.
- A test SHOULD fail with a clear reason.
- A test SHOULD distinguish setup failure from assertion failure.
- A test SHOULD avoid overfitting to implementation details unless that detail
  is part of the contract.
- A test MUST NOT silently pass if its oracle was not evaluated.


REPORTING RULES
---------------
A test result SHOULD express:
- test name,
- status: pass | fail | skip | error,
- execution time,
- diagnostic message,
- trace target(s) when applicable.

If a test is skipped, the reason SHOULD be explicit.
If a test fails, the oracle mismatch or environmental blocker SHOULD be explicit.

REPORTING STYLE
---------------
Where practical, a test report SHOULD include:
- what was tested,
- what was observed,
- what was expected,
- what changed,
- why the result is acceptable or not.

This keeps test output aligned with Baseliner-style contract reporting.


INTEROPERABILITY
----------------
TIC MAY be used alongside:
- pre-flight validation frameworks,
- execution contracts,
- contract tests,
- property-based tests,
- integration tests,
- regression suites,
- end-to-end validation.

TIC does not require any particular testing style.


SCOPE LIMITS
------------
TIC does not define:
- product state,
- execution counters,
- transition rules,
- destructive action policy,
- domain-specific configuration semantics,
- UI/UX behavior,
- language-specific test APIs.

Those belong to the relevant product contract or implementation layer.

If a codebase uses a contract model like Baseliner, that model SHOULD remain the
source of truth for runtime semantics, while TIC remains the source of truth for
test specification.


END OF SPEC
