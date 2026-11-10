# Feature specs

One file per feature: `docs/specs/<feature-name>.md`. A spec says what a
feature does, where each part lives, and how it appears on iPhone, iPad
and Mac. It is what an implementation is verified against.

**The rule:** a feature behaves the same on every app unless its spec
lists the difference, with a reason, under "Platform differences".

Specs are written and verified by the `architect` agent
(`.claude/agents/architect.md`). Older features are described in
`DESIGN.md`, `docs/ios.md`, `docs/bundles.md` and
`docs/ios-intelligence.md`; a spec links to those instead of repeating
them.

## Template

```markdown
# <Feature name>

Status: Draft | Approved | Implemented | Verified — <PR link>
Related: <design docs, earlier specs>

## What and why

Two or three sentences in the owner's words. What problem it removes.

**Out of scope:** what this deliberately does not do.

## Behaviour

Numbered, each one checkable. Include the edge cases: offline, two
accounts, empty state, a change arriving from another device, Undo.

- R1. …
- R2. …

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | rules, types, migrations |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | new `Engine` operations and records |
| Shared shell (`ios-app/HeyPigeon`) | `AppModel` methods, shared views, settings |
| iPhone / iPad only | … |
| Mac only (`macos-app/HeyPigeonMac`) | … |

Syncs between devices: yes/no — what, and how conflicts resolve.
Leaves the device: nothing | what, to whom, and the privacy sentence.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | | | |
| Entry points (gesture, key, menu, palette, intent) | | | |
| Settings | | | |
| Status | | | |

## Platform differences

Every intended deviation in behaviour, with its reason. "None" means
identical.

## Acceptance criteria

- [ ] R1 — proven by `<test name>` / `<file>`
- [ ] Same wording and symbol on every platform
- [ ] `MockEngine` covers the new operations
- [ ] `rust-ci`, `ios-ci`, `macos-ci` green
- [ ] Guides and privacy copy updated

## Open questions / assumptions

Choices the request left open and what was assumed.

## Verification

The architect's last report (verdict, date, what was not checked).
```
