# rails-conformity

Convention lifecycle engine for Rails. Measure, compare, recommend.

Deviations either *conform* (code moves to the convention) or get *codified*
(the convention grows to absorb validated patterns). The registry is the source
of truth; enforcement (CI + hooks), steering (AGENTS.md + docs/conventions),
and code (generators) are all rendered from it.

Status: v0.1.0 prototype. See `lib/tasks/conformity_tasks.rake` for the
command surface.

## Known limitations (prototype scope)

- Convention detectors are regex/structure-based, not full AST analysis; tuned
  for scaffold-shaped CRUD controllers.
- `provenance/scaffold_deviation` compares against `scaffold_controller`
  rendered with `--no-orm` (known upstream gap: that mode emits unpermitted
  `params.fetch` — see `~/rails-ai/UPSTREAM_PROPOSAL.md`).
- `codify_cop` ships one embedded proposal (raw-SQL); the corpus-test harness
  is generic, the proposal catalog is not.
- `Engine#check` gates on error/warning severities; `info` findings
  (`repeated_pattern`, `scaffold_deviation`) are triage signals and never block.
