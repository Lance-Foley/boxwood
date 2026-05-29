# App container owns the dev server process

**Status:** accepted

The session's `app` container runs the dev server as its own command (`foreman start -f Procfile.dev`, the golden image's default CMD) rather than running `sleep infinity` while a tmux pane execs `bin/dev` into it. We made this change because the manual model left the server silently down after any container restart: `detect_session_state` recreates the container on a `restart`, but `launch_tmux` reattaches to the existing tmux session without re-sending `bin/dev`, so nothing brings the server back up. Letting Docker own the process makes start/restart/crash-recovery automatic and ties the server's lifecycle to the container instead of a tmux pane.

## Considered options

- **app `sleep infinity` + manual `bin/dev` in a tmux pane** (previous approach). Gave one-keystroke Ctrl-C/restart and live control of the server pane, but did not survive container restarts and coupled the server to the tmux session. Rejected.
- **Keep manual, but re-send `bin/dev` on resume when the server isn't running.** Patches the symptom but keeps the server's lifecycle owned by tmux rather than Docker. Rejected as more fragile.

## Consequences

- The tmux "dev" pane becomes `docker compose -p <project> logs -f app` (read-only tail) instead of an interactive server shell. To restart the server you now use `docker compose restart app` (or re-run via the in-container shell pane) rather than Ctrl-C in the pane.
- The compose template drops `command: sleep infinity`; the `app` healthcheck (db-init marker) continues to gate the `worker`.
