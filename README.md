# rails-conformity

A convention engine for Rails apps. It finds code that drifts from your team's conventions, blocks new drift at the gate, and turns proven patterns back into conventions.

## Why this project

Conventions rot. Here's the usual cycle:

1. The team agrees on a convention.
2. People (and AI agents) write code that ignores it.
3. Reviewers catch some of it. Most of it ships anyway.
4. Nobody enforces the convention until someone rewrites the same file five times.

rails-conformity breaks the cycle. It works like a ratchet:

- Record the debt you have today as a baseline.
- Block every new violation. Old debt stays allowed.
- As you fix old debt, the baseline shrinks. It can only get tighter.
- When the same pattern repeats, codify it. Turn it into a generator or a RuboCop cop so the next person never writes it by hand.

The point: compliance goes up, effort goes down, and the gate never gets looser by accident.

Where rules live, by determinism. Move rules down the ladder as they mature:

- **Judgment-after**: review, security review.
- **Deterministic-after**: cops, specs, CI, the gate.
- **Deterministic-before**: generators, tool permissions, hooks.

Rules flow judgment-after → deterministic-after → deterministic-before. Codify to move them. One registry, rendered everywhere.

## Install

```bash
gem "rails-conformity", path: "gems/rails-conformity"   # or your git source
bin/rails g conformity:install --no-interactive
```

The install generator:

- Records the baseline from your current findings.
- Writes `AGENTS.md` and `docs/conventions` from the registry.
- Wires hooks for git (pre-push), Claude, Codex, and OpenCode.

### RuboCop config

We ship **no** `.rubocop.yml` and never will. You either use the one RuboCop
itself provides (its built-in defaults — do nothing) or your own team config if
you already have one. How strictly the gate treats rubocop goes in
`config/conformity.yml` (`checks.rubocop.mode: strict` or `advisory`).

### Specs

rspec is first-class: codify a family whose members have `spec/**` files and
the produced generator writes specs too (multi-file role, round-trip tested).
Minitest apps write tests by hand for now.

## Use

### 1. See what drifted

```bash
bin/rails conformity:report
```

Result:

```
score: 87  2 new finding(s), 4 known finding(s)
  error: convention/strong_params: app/controllers/gadgets_controller.rb uses params[:gadget] instead of strong params
  warning: convention/missing_controller_tests: app/controllers/gadgets_controller.rb has no request specs
  -> regenerate: bin/rails g scaffold_controller Gadget ...
```

The report recommends a fix strategy for each finding. Regenerate, run the fix, move on.

### 2. Gate on new violations

```bash
bin/rails conformity:check
echo $?
```

Result, when clean:

```
conformity: green (baseline ratchet honored)
0
```

Result, when someone adds a bad controller:

```
error: convention/strong_params: app/controllers/gadgets_controller.rb ...
conformity: 2 new finding(s) — gate failed
2
```

Exit 0 passes. Exit 2 fails. Wire it to CI or a pre-push hook and bad code stops at the door.

### 3. Triage old debt by hand

The baseline keeps old debt allowed. When you're ready to fix some of it:

```bash
bin/rails conformity:triage
```

For each finding you choose:

- `[c]odify` — turn the pattern into a generator or cop.
- `[e]xempt` — record a dated exemption in the registry (expires in 6 months).
- `[k]eep` — leave it in the baseline.

### 4. Codify a repeated pattern

Four services on the team share the same shape? Don't write the fifth one.

```bash
bin/rails "conformity:codify_generator[app/services/route_alert.rb,app/services/dock_alert.rb]"
```

Result:

```
conformity: round-trip PASSED — lib/generators/team/alert/team/alert_generator.rb
```

The engine extracts a template, proves it can rebuild every original file (the round-trip test), then writes the generator and registers it. If the round-trip fails, nothing is written.

From then on:

```bash
bin/rails g team:alert Fog
```

### 5. Codify a cop

Raw SQL in `where` keeps sneaking in? Codify the cop. The cop must pass a corpus test: it has to flag the bad examples and pass the good ones. Fail either and the cop is rejected.

```bash
bin/rails conformity:codify_cop
```

Result:

```
conformity: corpus test PASSED — cop registered (missed: 0, false hits: 0)
```

### 6. Keep steering docs in sync

The registry is the source of truth. `AGENTS.md` and `docs/conventions` are rendered from it.

```bash
bin/rails conformity:sync
```

Result:

```
conformity: synced AGENTS.md, docs/conventions
```

Changed the registry by hand? `conformity:check` detects the drift and fails the gate. Run `sync` to fix it.

### 7. Fast checks in editors and agents

`bin/conformity` runs without booting Rails, so hooks stay fast:

```bash
echo '{"tool_input":{"file_path":"app/services/route_alert.rb"}}' | bin/conformity edit-check
echo $?   # 2, with a terse offense on stderr
```

Edit hooks (Claude, Codex, OpenCode) call `edit-check` per file. Stop hooks call `changed-check`, which escalates to the full gate when the ratchet is at risk.

## Known limitations (prototype scope)

- Convention detectors are regex/structure-based, not full AST analysis; tuned for scaffold-shaped CRUD controllers.
- `provenance/scaffold_deviation` compares against `scaffold_controller` rendered with `--no-orm` (that mode emits unpermitted `params.fetch` — an upstream Rails gap).
- `codify_cop` ships one embedded proposal (raw SQL); the corpus-test harness is generic, the proposal catalog is not.
- `info` findings (`repeated_pattern`, `scaffold_deviation`) are triage signals and never block the gate.

## License

MIT
