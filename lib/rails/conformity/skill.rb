module Rails
  module Conformity
    # Ships the per-app agent playbook (SKILL.md) so every host that reads
    # skills gets the same decision tree for working under the gate.
    class Skill
      PATH = File.join(".claude", "skills", "conformity", "SKILL.md").freeze

      CONTENT = <<~MARKDOWN
        ---
        name: conformity
        description: Conventions playbook for this codebase (conformity engine). Use when the conformity gate or edit-check fails, when touching app/services, controllers, models, or jobs, or when asked to codify, reject, or exempt a pattern.
        ---

        # Conformity playbook

        `conformity/registry.yml` is the source of truth for conventions.
        `bin/rails conformity:sync` renders `AGENTS.md` and `docs/conventions/*` from it.
        Read the topic doc for whatever you are touching (see AGENTS.md "Read when").

        ## Hard rules

        - Never edit `AGENTS.md` or `docs/conventions/*` by hand. They are rendered; the gate flags drift. Edit the registry, then run `bin/rails conformity:sync`.
        - Never hand-write a pattern listed in docs/conventions/codified.md. Run the listed generator command.
        - Never add `# rubocop:disable` without a registry exemption.

        ## Gate behavior

        - `bin/rails conformity:check`: green = nothing new versus the baseline ratchet. Exit 2 prints the new findings on stderr — fix the code, or ask the user before weakening anything.
        - Edit hooks run `bin/conformity edit-check` per touched file: it flags only baseline-new findings, so legacy debt files pass silently. Exit 2 means fix or ask.
        - `bin/conformity changed-check` escalates to the full gate (runs the suite).

        ## Repeated patterns

        `convention/repeated_pattern` means "codify candidate — do not copy-paste". Propose exactly one of:

        1. **Codify** (if the pattern is good): `bin/rails "conformity:codify_generator[file1,file2]"`.
           Acceptance is the round-trip test: the template must reproduce every original byte-for-byte. On success, register + steering update automatically.
        2. **Reject** (if the pattern is unhealthy): ask the user; record `kind: reject` in the registry with a note like "TODO: refactor; do not copy this pattern". It stays visible as an annotated finding and lands in docs/conventions/codify.md.
        3. **Keep** (undecided): leave it; it stays in the baseline silently.

        ## Codify loop

        1. Pick 2+ structurally identical members. Their test files (`spec/**` or `test/**`) join the pattern automatically when present.
        2. `bin/rails "conformity:codify_generator[...]"` → round-trip PASSED.
        3. Generate features: `bin/rails g team:<name> <Name>` — comes out with the codified namespace, doc comments, and test skeleton.
        4. Fix per-member slots (the `call` body, expected values in tests) — defaults are member 1.
        5. Run the member's tests, then the gate. Green means the loop is closed.

        ## Debt and exemptions

        - Exemptions are dated (6 months) and shown in steering; renewing needs a fresh user decision.
        - The baseline only shrinks through fixes; run `bin/rails conformity:baseline` only after genuine debt fixes or after codifying a cop that matches pre-existing code (so old matches stay allowed).
      MARKDOWN

      def write(app_root)
        path = File.join(app_root, PATH)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, CONTENT)
        path
      end
    end
  end
end
