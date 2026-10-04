# rails-conformity

A convention engine for Rails apps. It blocks new violations, tracks old debt, and turns repeated patterns into generators.

## Why

Conventions rot. People and AI agents ignore them. Reviewers miss things. Nobody enforces anything until the same file gets rewritten five times.

rails-conformity works like a ratchet:

1. Record the debt you have today as a baseline.
2. Block every new violation. Old debt stays allowed.
3. Fix debt, and the baseline shrinks. It never gets looser by accident.
4. When the same pattern repeats, codify it. Generate it from then on.

## Get started

Add the gem and install:

```bash
gem "rails-conformity", path: "gems/rails-conformity"   # or your git source
bundle install
bin/rails g conformity:install --no-interactive
```

The install generator:

- Records the baseline from your current findings.
- Writes `AGENTS.md` and `docs/conventions` from the registry.
- Ships the agent playbook `.claude/skills/conformity/SKILL.md`.
- Wires hooks: git pre-push, Claude, Codex, OpenCode.

That's it. The gate now runs on every push and on every agent edit.

## Daily use

| Command | What it does |
| --- | --- |
| `bin/rails conformity:report` | Score, findings, and fix suggestions for your changes. |
| `bin/rails conformity:check` | The gate. Exit 0 = green, exit 2 = new findings. |
| `bin/rails conformity:triage` | Walk every finding: codify, exempt, reject, or keep. |
| `bin/rails conformity:sync` | Re-render steering docs from the registry. |

### Example: the gate

```bash
bin/rails conformity:check
```

Clean:

```
conformity: green (baseline ratchet honored)
```

A new violation:

```
error: convention/strong_params: app/controllers/gadgets_controller.rb ...
conformity: 1 new finding(s) — gate failed     # exit 2
```

The report tells you how to fix it:

```bash
bin/rails conformity:report
# -> regenerate: bin/rails g scaffold_controller Gadget ...
```

## Codify a repeated pattern

Four services share the same shape? Don't write the fifth one. Pick two members:

```bash
bin/rails "conformity:codify_generator[app/services/pricing/subtotal_calculator.rb,app/services/pricing/discount_calculator.rb]"
# conformity: round-trip PASSED — lib/generators/team/calculator/...
```

Acceptance is deterministic: the extracted template must rebuild every original file byte-for-byte. Fail that, and nothing is written.

Then the fifth member is one command:

```bash
bin/rails g team:calculator CartHandling
```

It comes out with the right module, doc comment, and (if the family has tests) a test file. Fix the one line that differs — the `call` body — run the tests, done.

## Codify a cop

Raw SQL in `where` keeps sneaking in? Codify the cop. It must pass a corpus test: flag every bad example, stay silent on every good one.

```bash
bin/rails conformity:codify_cop
# conformity: corpus test PASSED — cop registered (missed: 0, false hits: 0)
```

## Reject a pattern

Found a family you don't want? Mark it in triage with `[r]eject`, or add a `kind: reject` entry to `conformity/registry.yml`:

```yaml
- id: reject-legacy-parsers
  kind: reject
  paths: [app/services/legacy_parser.rb]
  note: 'TODO: refactor; do not copy this pattern'
```

Rejected patterns never block the gate, but they stay visible in reports with your note, and render into `docs/conventions/codify.md` so nobody copies them. Run `bin/rails conformity:sync` after editing the registry.

## Rules for agents

Steering is generated. Never edit `AGENTS.md` or `docs/conventions` by hand — edit the registry and run `conformity:sync`. The gate flags hand-edits as drift, like a stale `schema.rb`.

## Small print

- **RuboCop config**: we ship no `.rubocop.yml`. Use RuboCop's built-in defaults or your own team config. How strictly the gate treats rubocop: `config/conformity.yml` (`checks.rubocop.mode: strict` or `advisory`).
- **Specs and tests**: both rspec and Minitest are supported. If family members have `spec/**` or `test/**` test files, the generated members get tests too.
- **Registry is source of truth**: steering, provenance, and generators all derive from `conformity/registry.yml`.

## Known limitations (prototype scope)

- Convention detectors are regex/structure-based, not full AST analysis; tuned for scaffold-shaped CRUD controllers.
- `provenance/scaffold_deviation` compares against `scaffold_controller` rendered with `--no-orm` (that mode emits unpermitted `params.fetch` — an upstream Rails gap).
- `codify_cop` ships one embedded proposal (raw SQL); the corpus-test harness is generic, the proposal catalog is not.
- After `codify_cop`, run `conformity:baseline` once so the cop's pre-existing matches stay allowed.
- `info` findings (`repeated_pattern`, `rejected_pattern`) never block the gate.

## License

MIT
