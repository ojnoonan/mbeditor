# Standalone editor process

- **Status:** Design
- **Date:** 2026-08-17

## Problem

mbeditor runs as a mountable engine inside the host Rails app, so the editor shares the
host's fate. Every one of these has been hit in practice:

- A pending migration made `ActiveRecord::Migration::CheckPending` raise on every request,
  including the editor's — the tree, opening a file and saving one all failed, and the
  migration that caused it could not be edited.
- A syntax error in `config/routes.rb` wipes every registered route set, taking the engine's
  mount with it.
- Saving files in the host's autoload paths triggers a reload, whose interlock serialises
  requests; a burst of saves outran the server and latency grew without bound.
- `byebug`/`debug` suspend every thread, including the one serving the editor.
- A raising initializer or a dependency conflict stops the app booting, and the editor with it.

Each has been mitigated separately, and each mitigation is one failure mode behind. The
common cause is that the editor is in the host's process. The editor's job — reading and
writing files — needs nothing from that process.

## Goal

Run the editor as its own process so that host-app breakage cannot stop a developer editing
files, while keeping the current mounted mode exactly as it is.

## Non-goals

- Replacing the mounted mode. This adds a second way to run the same engine.
- Surviving a broken `Gemfile`. The gem stays an ordinary bundle entry (see Decisions), so
  dependency resolution failures still stop it. This is the rarer failure and the price of
  plug-and-play installation.
- Any new runtime dependency. The gem already depends on `rails` and `sprockets-rails`.

## Decisions

| Question | Decision |
| --- | --- |
| How separate? | Own process, never loads the host's `config/environment`. |
| Where does the gem live? | Ordinary entry in the host `Gemfile`, as today. Plug-and-play. |
| Host-coupled features | Hidden in standalone rather than shown as unavailable. |
| Auth when host auth is configured | Standalone starts, protected by its own mandatory token. |

## Scope

**In:** CLI entry point, minimal Rails application, capability flag and client gating,
standalone authentication, tests.

**Out:** changes to any existing service, controller or component beyond gating the four
host-coupled features and reading the capability flag.

## Architecture

`bundle exec mbeditor [--port N] [--path DIR]` boots
`Mbeditor::Standalone::Application < Rails::Application` in the current process. It mounts
the existing `Mbeditor::Engine` at `/` and sets `workspace_root` to `--path` (default: cwd).

It never requires the host's `config/environment`, so no host initializer, model, route or
migration check runs. Rails' HTTP stack, Sprockets and ActionCable are loaded from the
bundle the gem already depends on.

Everything downstream of routing is unchanged: the same controllers, the same services, the
same assets. The engine does not know which application mounted it.

```
mounted mode      host Rails app ── mounts ──> Mbeditor::Engine
standalone mode   mbeditor CLI ──> Standalone::Application ── mounts ──> Mbeditor::Engine
```

Memory is roughly 80–120 MB and flat in the size of the host app, because the host app is
never loaded. This is not purely additive: editor traffic stops competing for the host
Puma's threads and stops tripping the reloader interlock, so the host server gets lighter.

## Capability flag

`Mbeditor.standalone?` is true only under `Standalone::Application`. It is reported to the
client through the existing `/client_config` payload as `standalone: true`.

Four features need the host app loaded and are hidden when the flag is set:

| Feature | Why it needs the host process |
| --- | --- |
| Model graph | `reflect_on_all_associations` + `Rails.application.eager_load!` |
| Route hints | reads `Rails.application.routes` |
| Model schema | ActiveRecord column introspection |
| Runtime exceptions | subscribes to the host's `process_action.action_controller` |

Client: the model-graph activity-bar button, the route-hint decorations, the schema links
and the Problems panel's exceptions section are not rendered. Server: those endpoints
return `501` with a clear message, so a stale client gets an explanation rather than a
stack trace. Hiding rather than empty-stating was chosen so there are no dead ends in the
UI and no four extra states to keep accurate.

## Authentication

The editor grants arbitrary read/write inside the workspace and spawns subprocesses
(rubocop, ruby-lsp, tests, git). Reaching its port is equivalent to code execution on the
developer's machine, so it must never be open.

Standalone cannot run the host's `authenticate_with`: it is a proc closing over host models
and the session, and the entire point of this mode is to work when those cannot load. The
only honest options are to refuse to start or to require a credential of our own. "Open
because we could not check" is not one of them.

- **A token is mandatory and cannot be disabled.** Generated per launch, printed in the
  startup URL. There is deliberately no insecure-mode flag, because that is the flag that
  gets left on.
- **The token is exchanged for a session cookie** on first load (httpOnly, `SameSite=Strict`),
  so it does not persist in the address bar, shell history or server logs.
- **Enforced before anything else** — ahead of `resolve_path` and every file operation, and
  on the ActionCable connection, which is a separate door to the same data.
- **Binds to `127.0.0.1` by default.** This is defence in depth, not the control. Binding
  elsewhere requires an explicit flag and still requires the token.
- **Stated at startup**: host authentication is unavailable in this mode and the token is
  what protects the session. The downgrade is never silent.

Standalone starts even when the host configures `authenticate_with`. Whoever launches it
already has shell and filesystem access to the project, so the token holder gains nothing
they did not already have — and refusing would remove the tool exactly when the app is
broken. The mounted mode is untouched: `authenticate_with` applies there as it does today.

## Risks

**Sprockets outside a host app** is the one real unknown: the engine's asset paths are
normally registered into the host's Sprockets environment. This must be proven before the
rest is built (see Plan).

**Two modes to keep working.** Mitigated by the engine being identical in both — only the
application wrapping it differs — and by tests asserting the mounted mode is unchanged.

**ActionCable standalone** needs the async adapter; it is in-process and single-server, which
is what collaboration and `files_changed` already assume in development.

## Testing

- Standalone boots: editor page 200, `/files` 200, a save round-trips to disk.
- The four host-coupled endpoints return 501 and `/client_config` reports `standalone: true`.
- **Auth:** no token is rejected; a wrong token is rejected; the token exchanges for a cookie
  and subsequent requests succeed; the cable connection rejects an unauthenticated socket.
  These are the tests that must not be allowed to rot.
- Mounted mode is unaffected: the existing suite passes unchanged, including
  `authenticate_with` behaviour.
- A host app that cannot boot (raising initializer) does not prevent standalone starting.

## Plan

1. **Spike:** prove Sprockets serves the engine's assets from a minimal Rails application.
   Everything else depends on this; if it fails, reconsider before building further.
2. CLI + `Standalone::Application`, workspace root wiring.
3. Token authentication and the cable guard.
4. Capability flag, server 501s, client gating.
5. Tests.
