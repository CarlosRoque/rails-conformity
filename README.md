# rails-conformity

Convention lifecycle engine for Rails. Measure, compare, recommend.

Deviations either *conform* (code moves to the convention) or get *codified*
(the convention grows to absorb validated patterns). The registry is the source
of truth; enforcement (CI + hooks), steering (AGENTS.md + docs/conventions),
and code (generators) are all rendered from it.

Status: skeleton (Step 0). See `lib/tasks/conformity_tasks.rake` for the
command surface.
