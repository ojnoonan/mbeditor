# ADR-0001 — No frontend build step; frontend stays on `React.createElement`

- **Status:** Accepted
- **Date:** 2026-05-29
- **Deciders:** Anthony Georges

## Context

mbeditor ships as a mountable Rails engine gem, used at development time and mounted into
host Rails apps. A long-standing invariant (CLAUDE.md) is **"No build step — edit files
directly."** The frontend is plain JS + React + Monaco; React components are authored with
`React.createElement` and served as-is by Sprockets. Vendored libs live in `vendor/assets/`.

Six untracked `*.js.jsx` files had accreted in `app/assets/javascripts/mbeditor/components/`
(`MbeditorApp`, `EditorPanel`, `FileTree`, `GitPanel`, `TabBar`, `QuickOpenDialog`) — real
angle-bracket JSX rewrites of committed components. They evolved organically rather than
from a deliberate decision, were wired into nothing (`application.js` requires the `.js`
files; no `.jsx` transformer is registered in Sprockets 4.x), and several were also
*feature-reduced* (the `.jsx` `EditorPanel`/`FileTree` had dropped blame, conflict
resolution, virtual scrolling, and multi-select).

"No build step" carries two distinct weights:

- **Consumer-facing (hard line):** anyone who `bundle install`s mbeditor must not need
  Node/npm/a bundler for the editor to work. This is the gem's "just mount it" value
  proposition.
- **Maintainer-facing (nice-to-have):** editing a `.js` and reloading, with no compile step
  in the loop.

Real angle-bracket JSX cannot run unparsed, so it breaks the maintainer loop unconditionally
and breaks the consumer guarantee under any transpile-at-consumer approach. Crucially, JSX
would not solve the actual maintainability problem in `MbeditorApp` — the absence of
*interaction seams* (keyboard routing, resize, lint orchestration), which is identical in
JSX and in `React.createElement`. JSX prettifies the render tree and nothing else.

## Decision

The frontend is authored in plain JavaScript using `React.createElement`, served as-is by
Sprockets, with **no transpiler and no bundler**. Consumers must need **zero JS tooling**.

If JSX-like ergonomics are ever revisited, the only admissible routes are:

- **`htm`** — runtime tagged-template literals (~700 bytes), no build step; or
- **in-browser Babel standalone** — transpile at page load (heavy, but dev-only).

A Sprockets `.jsx` transformer (or any approach requiring Node/ExecJS at the consumer's
asset-compile or asset-serve time) is **not admissible** — it breaks the zero-tooling line.

The six `*.js.jsx` spike files are removed.

`MbeditorApp` and `editor_plugins.js` maintainability is addressed by extracting
modules/seams (see the 2026-W22 architecture review), **not** by changing syntax.

## Consequences

- Render trees stay verbose (`React.createElement` chains). Accepted.
- The zero-tooling consumer guarantee is preserved and now explicit.
- Future architecture reviews (and AI agents) should **not** re-suggest a JSX migration;
  point them here.
- Frontend depth problems are solved structurally (module extraction), independent of syntax.
