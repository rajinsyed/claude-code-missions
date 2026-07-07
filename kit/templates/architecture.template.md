# Architecture — <mission title>

<!-- Binding design document for THIS mission. Workers must follow the contracts here exactly; deviations require returning to the orchestrator with evidence. -->

## Purpose

<!-- Why the system exists and the core approach, in a few sentences. -->

## System overview

<!-- Components and how they talk to each other. A small ASCII diagram helps. -->

## Repository layout

<!-- The directory tree the mission produces/modifies, with one-line annotations per entry. -->

```
<repo>/
├── ...
```

## Contracts

<!-- Numbered sections (§1, §2, ...) that feature descriptions can reference. Interfaces, schemas, file formats, exact strings, and exit-code semantics live here. Be precise: workers copy contract-mandated strings character-for-character. -->

### §1 <first contract>

## Data & state

<!-- Persistent state: files, databases, schemas. Who writes what, who may never write what. -->

## Testing strategy

<!-- How correctness is proven: test entrypoint, sandboxing rules, what the gate command is. -->

## Known gaps / non-goals

<!-- Deliberate limitations. Document them; do not silently "fix" them. -->
