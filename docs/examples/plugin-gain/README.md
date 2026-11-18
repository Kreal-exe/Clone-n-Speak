# Example plugin: Gain

A plugin is a folder with `plugin.json` and an entry file (`main.py`) that defines `run(action, inputs, ctx)`.
Return `{"outputs": ["name.wav"], "text": "..."}`; output names are relative to `ctx.work_dir`.

What the sandbox allows (each run is a new process under `sandbox-exec`):

- Writes only to `ctx.work_dir` and `ctx.data_dir` (also `HOME`). Everything else is read-only.
- Reads: system libraries and Python, the plugin's own folder, its two folders above and the input files of the
  current run. Your home folder (documents, keys, app data) and `/Volumes` are not readable.
- Network only when `plugin.json` has `"permissions": ["network"]`, you allowed it, and Offline mode is off.
- It cannot start `open`, `osascript`, `launchctl`, `shortcuts`, `screencapture` and similar programs, nor anything it
  wrote itself, and cannot reach LaunchServices or Apple Events.
- The timeout (`timeout_s`, at most 3600) is enforced by the app; Stop and the timeout kill the whole process tree.

It cannot signal other processes (only itself and its own children).

Known limit: a child that double-forks, calls `setsid` and is re-parented to launchd within half a second (between two
samples of the process tree) can outlive Stop. The app also looks for such orphans by a per-run token in their
environment, but `ps` cannot show the environment of every binary (not that of the app's own Python build) and a
plugin can scrub it, so this is best effort. Such a process still runs inside the sandbox above.
