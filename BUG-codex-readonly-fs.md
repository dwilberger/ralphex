# Bug: codex external review fails with read-only filesystem in container

## Summary

Two consecutive ralphex autonomous runs against project `compliance-pnh` completed all claude phases successfully (implementation + 3 claude review iterations with real bugs caught and fixed), but failed at the final **codex external review** phase with identical `Read-only file system (os error 30)` errors during codex session initialization.

The codex binary inside the ralphex container tries to write to `/home/app/.codex/` paths (skills, models cache, session state) which are mounted read-only from the host. Codex crashes before it can do any review work, ralphex marks the run as `exit status 1`, and the container exits.

**Net impact**: the external codex review stage is effectively non-functional on this setup. Runs are still useful because claude reviews catch real bugs, but the "second opinion" layer that codex was meant to provide is missing. Ralphex also returns non-zero exit, which makes it look like the whole run failed when in practice the implementation + claude reviews succeeded.

## Environment

- Host: Windows 11 (bash via Git Bash)
- Docker: running on Windows Desktop
- Ralphex image: `ghcr.io/umputun/ralphex:latest` (v0.27.2-9fd2f40-20260416T183340)
- Project mounted: `C:/Users/Daniel/git/compliance-pnh` → `/workspace`
- Codex configs: `~/.codex/` mounted into container

## Incident 1 — 2026-04-18, run `rule-engine-hardening`

- **Container name**: `ralphex-compliance-pnh-2026-04-18-rule-engine-hardening`
- **Plan**: `docs/plans/2026-04-18-rule-engine-hardening.md` (15 tasks)
- **Claude phase duration**: ~1.5 hours
- **Exit code**: 1
- **Commits produced before failure**: 19 (15 feat covering all tasks + 4 fix from 3 claude review iterations)
- **Branch preserved**: yes — worktree auto-removed cleanly before codex failure
- **Real bugs caught by claude reviews (not by codex)**:
  - `executeRule`/`executeAllRules` inflating `tbl_rule_runs.total_occurrences` by returning pre-dedup rows
  - `finishRun` silently swallowed, leaving runs stuck `status='running'`
  - `maybeCatchUpMissedRun` using `startedAt` instead of `finishedAt ?? startedAt`
  - `LOCK_KEY_HI/LO` encoding wrong string ("RZHE"/"S5pN" vs "RULESRUN")
  - `finishRun` with 0 rules marking run as `failed`, causing infinite catch-up
  - Missing calendar date validation
  - `withBatchLock` masking DB errors as lock conflicts

### Codex error tail (incident 1)

```
--- codex external review ---
--- codex iteration 1 ---
removed worktree: /workspace/.ralphex/worktrees/rule-engine-hardening
error: runner: codex loop: codex execution: codex exited with error: command wait: exit status 1
stderr: Reading prompt from stdin...
2026-04-19T00:28:01.757560Z ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)
2026-04-19T00:28:02.942296Z ERROR codex_models_manager::cache: failed to write models cache: Read-only file system (os error 30)
2026-04-19T00:28:02.967669Z ERROR codex_core::codex: Failed to create session: Read-only file system (os error 30)
Error: thread/start: thread/start failed: error creating thread: Fatal error: Failed to initialize session: Read-only file system (os error 30)
```

## Incident 2 — 2026-04-19, run `occurrence-events-model`

- **Container name**: `ralphex-compliance-pnh-2026-04-18-occurrence-events-model`
- **Plan**: `docs/plans/2026-04-18-occurrence-events-model.md` (10 tasks)
- **Claude phase duration**: ~3.75 hours (larger plan, more review iterations)
- **Exit code**: 1
- **Commits produced before failure**: 14 (10 feat covering all tasks + 4 fix from 3 claude review iterations)
- **Branch preserved**: yes — worktree auto-removed cleanly before codex failure
- **Real bugs caught by claude reviews (not by codex)**:
  - Missing test for invariant `escalated → novo caso` (rule documented but not enforced by any test)
  - Stale closure in `PlayerOccurrencesTable.toggleExpand` causing duplicate API calls on rapid double-click — fixed with `useRef`-backed `inFlightRef`

### Codex error tail (incident 2)

```
--- codex external review ---
--- codex iteration 1 ---
removed worktree: /workspace/.ralphex/worktrees/occurrence-events-model
error: runner: codex loop: codex execution: codex exited with error: command wait: exit status 1
stderr: Reading prompt from stdin...
2026-04-19T04:29:31.532705Z ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)
2026-04-19T04:29:32.465479Z ERROR codex_models_manager::cache: failed to write models cache: Read-only file system (os error 30)
2026-04-19T04:29:32.490092Z ERROR codex_core::codex: Failed to create session: Read-only file system (os error 30)
Error: thread/start: thread/start failed: error creating thread: Fatal error: Failed to initialize session: Read-only file system (os error 30)
```

## Incident 3 — 2026-04-19, run `rules-dry-run-reuse-and-audit`

- **Container name**: `ralphex-compliance-pnh-2026-04-19-rules-dry-run-reuse-and-audit`
- **Plan**: `docs/plans/2026-04-19-rules-dry-run-reuse-and-audit.md` (16 tasks)
- **Claude phase duration**: ~3 hours (including 3 claude review iterations, with a 20-minute session timeout on review iteration 2 that triggered an automatic retry into iteration 3)
- **Exit code**: 1
- **Ralphex image**: `ralphex-go-local:dev` (contains the 2026-04-19 resolution patches — boot probe, error classification, banner)
- **Commits produced before failure**: 18 (16 feat covering all tasks + 2 fix from 3 claude review iterations)
- **Branch preserved**: yes — worktree auto-removed cleanly before codex failure
- **Real bugs caught by claude reviews (not by codex)**:
  - `discardDryRun` clearing local state even on HTTP error, hiding failures
  - `getRuleHistory` `ORDER BY` on text-cast timestamps producing wrong sort under non-UTC session TZ
  - `upsertPlayerIdentity` hardcoding `mode: "scheduled"` even in UI-triggered execute path, polluting `tbl_dw_usage` metrics
  - `seed-rules.ts` bumping `updated_at` on idempotent runs (should only bump when parameters actually change)
  - `persistFromDryRun` non-atomic write paths (sql import missing, transaction boundary wrong)
  - `diffParams(form, saved)` argument order double-inverted, accidentally producing correct output but with unclear semantics

### Codex error tail (incident 3)

Note the compact format — this is the classified `CodexInfraError` banner from the 2026-04-19 fix. The full multi-line traceback from incidents 1-2 is no longer surfaced to the user.

```
--- codex external review ---

--- codex iteration 1 ---

================================================================
CODEX REVIEW FAILED -- INFRASTRUCTURE ERROR (readonly_fs)
================================================================
tool: codex
matched: 2026-04-19T19:00:57.093641Z ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)

likely cause and recovery:
  - Docker Desktop VM disk went read-only (corruption or mount failure)
  - try: `wsl --shutdown` then restart Docker Desktop
  - verify: `docker exec <container> dmesg | tail -30` should show EXT4-fs errors if corruption

claude review work on the branch is preserved. run exits non-zero.
================================================================
```

## Incident 4 — 2026-04-19, run `dw-cost-tracking` (parallel with incident 3)

- **Container name**: `ralphex-compliance-pnh-2026-04-19-dw-cost-tracking`
- **Plan**: `docs/plans/2026-04-19-dw-cost-tracking.md` (16 tasks)
- **Claude phase duration**: ~2.25 hours (faster than incident 3; smaller helper-shaped tasks early, and claude reviews converged in 3 iterations with no session timeouts)
- **Exit code**: 1
- **Ralphex image**: `ralphex-go-local:dev` (same patched image as incident 3)
- **Commits produced before failure**: 22 (16 feat + 3 fix from claude reviews + 3 meta "mark Task N complete")
- **Branch preserved**: yes — worktree auto-removed cleanly before codex failure
- **Real bugs caught by claude reviews (not by codex)**:
  - Dockerfile missing `COPY config/` to the runner stage, causing **server crash on startup** in production (critical — would have shipped broken)
  - `runCostBackfill` doing N sequential DB updates in error and unmatched paths, refactored to batched `inArray` updates
  - DMV reconciliation query bypassing preflight required `rawClient` export from `src/lib/dw/index.ts` (preflight rejects the query because it doesn't filter by `DwDate`)
  - `cost-backfill.ts` LIKE wildcards wrong, unused `startedAt` variable
  - `fillDailyGaps` using UTC `Date.now()` instead of BRT-aware helper, producing gaps at the wrong day boundary
  - `maxBackfillAttempts` config not propagated into `DwUsageTable` component, so the "pending" vs "failed" distinction in the UI was always computing against default rather than configured value
  - Wrong advisory lock comment (referenced old key scheme)
  - Test fixes (spy target moved, duplicate tests consolidated, improved cost assertion, trace-wrap regex precision)

### Codex error tail (incident 4)

Identical classified-error format as incident 3, different timestamp:

```
--- codex external review ---

--- codex iteration 1 ---

================================================================
CODEX REVIEW FAILED -- INFRASTRUCTURE ERROR (readonly_fs)
================================================================
tool: codex
matched: 2026-04-19T18:11:09.643251Z ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)

likely cause and recovery:
  - Docker Desktop VM disk went read-only (corruption or mount failure)
  - try: `wsl --shutdown` then restart Docker Desktop
  - verify: `docker exec <container> dmesg | tail -30` should show EXT4-fs errors if corruption

claude review work on the branch is preserved. run exits non-zero.
================================================================
```

## Validation notes from incidents 3 and 4

Both runs used the patched `ralphex-go-local:dev` image and fired through `/c/Users/Daniel/git/orchestration-setup/scripts/ralphex-run.sh` (after the wrapper was patched to honor `RALPHEX_IMAGE` env var and to mount `~/.claude.json` alongside `~/.claude`, which was missing before and caused a separate auth failure on the first attempt).

Observations about the 2026-04-19 resolution in real usage:

1. **Boot probe did not fire** in either run. Container init completed cleanly — the `~/.codex` mount was writable at startup. The failure appeared mid-run, ~2-3 hours in, when codex actually tried to touch the filesystem. This matches the stated scope of the fix ("catches pre-existing bad state at boot") and is not a regression — boot probe cannot predict a VM going read-only hours later.
2. **Error classification worked as designed**. Codex stderr was matched to the expected `Read-only file system` pattern, wrapped in `CodexInfraError`, and surfaced via the banner. The user (operator monitoring live) knew within seconds what happened and what to do. Compare to incidents 1-2 where the error was buried in a multi-line traceback and took 20+ minutes to parse.
3. **Banner recovery steps were correct**. After both runs completed, `wsl --shutdown` + restart of Docker Desktop cleared the VM state and a follow-up run would have been able to reach codex (not attempted in these incidents because the claude review work was already merge-ready).
4. **Parallel runs both hit EROFS**. Incidents 3 and 4 ran concurrently with `DASHBOARD_PORT=8080` and `DASHBOARD_PORT=8081`, each in its own git worktree (`--worktree`), each with its own named container. Both hit the read-only error at codex phase — incident 4 first (18:11 UTC, ~2.25h in), incident 3 second (19:00 UTC, ~3h in). This strongly suggests the failure is a property of the host Docker Desktop VM state rather than anything container-local. Running two containers in parallel did not cause the failure; either would have failed on its own given enough wall-clock time.

## Container startup warnings (non-fatal but related)

Both runs started with a flood of `chown: Read-only file system` errors on `/home/app/.codex/` paths during container init. Examples:

```
chown: /home/app/.codex/skills/.system/skill-installer/assets/skill-installer-small.svg: Read-only file system
chown: /home/app/.codex/skills/.system/skill-installer/SKILL.md: Read-only file system
chown: /home/app/.codex/skills/.system: Read-only file system
chown: /home/app/.codex/state_5.sqlite: Read-only file system
chown: /home/app/.codex/tmp/arg0/codex-arg0c8A28q/.lock: Read-only file system
chown: /home/app/.codex/tmp: Read-only file system
chown: /home/app/.codex/version.json: Read-only file system
chown: /home/app/.codex: Read-only file system
```

These are emitted by the entrypoint trying to `chown` mounted directories to the `app` user. They're cosmetic at boot time, but they foreshadow exactly what codex itself later fails on: the `.codex` mount is read-only, and codex's runtime requires write access for:

1. `codex_core_skills::manager` — wants to install/update system skills (removes and recreates the skills dir)
2. `codex_models_manager::cache` — wants to write models cache
3. `codex_core::codex` — wants to write session state (`state_*.sqlite`, `tmp/` arg staging)

Any of these failing is fatal for codex session start, which is why the first write attempt immediately aborts the run.

## Root cause hypotheses

1. **Ralphex runtime mounts `~/.codex` read-only by design** (probably to prevent the containerized codex from mutating host state), but codex itself **expects write access** to that path for normal session init. The two design assumptions conflict.
2. **Versioned codex binary has grown** to need more persistent state (sqlite, cached skills) than the original ralphex integration anticipated. Possibly worked fine at an earlier codex version that only needed read access.
3. **Skill installer is the first write attempt** (`codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir`) — codex wants to recreate its skills dir on every start, which clashes with read-only mounts.

## Suggested fixes (for ralphex side)

Only listing what's actionable inside the ralphex project — the real fix belongs upstream.

1. **Mount `~/.codex` read-write into a host tmpdir instead of read-only from the user's home**. A fresh per-run volume avoids polluting the host codex install, gives codex write access, and is thrown away at container exit. Rough sketch:
   ```bash
   # Launch-side (ralphex-run.sh or equivalent):
   CODEX_TMP=$(mktemp -d)
   cp -R ~/.codex/* $CODEX_TMP/ 2>/dev/null || true
   docker run \
     -v $CODEX_TMP:/home/app/.codex:rw \
     ...
   ```
   This keeps auth tokens available (copied in) without letting the container mutate the host.

2. **Alternative: `tmpfs` mount over `/home/app/.codex`** so writes are ephemeral in-container. Downside: codex auth state (tokens, MRU config) is lost and would need to be re-provisioned per-run via env vars, which may not be feasible if codex expects sqlite-backed state.

3. **Non-zero exit from codex phase should not bubble up as run failure** when all prior phases (tasks + claude reviews) succeeded. Ralphex could treat the codex phase as best-effort and exit 0 with a warning, since the output (branch + commits) is still valid. This decouples the "codex broken" issue from "did the run succeed".

4. **Container init script should detect the read-only mount on boot** and either (a) abort with a clear error message before wasting hours of claude work, or (b) auto-fall-back to a tmpfs overlay. Right now the chown errors are silenced and the user only learns about the issue 2-4 hours later.

## Workaround currently in use

Accept that codex review doesn't run. Treat the 3 claude review iterations as the quality gate. This has worked across both incidents — the 4 fix commits per run caught real bugs that would have otherwise shipped. The merge pipeline from the compliance-pnh side is documented and produces clean fast-forwards once the branch is reviewed manually.

## Resolution (2026-04-19)

Implemented per `docs/plans/2026-04-19-codex-readonly-diagnostics.md`:

1. **Boot-time probe** (`scripts/internal/init-docker.sh`): container aborts at init when `/home/app/.codex` is not writable after `cp -rL`. Saves hours of wasted claude work when Docker Desktop VM is in a bad state.
2. **Error classification** (`pkg/executor/codex.go`): codex stderr is scanned for `Read-only file system`, `No space left on device`, and `Failed to (initialize|create) session`. Matches produce a typed `CodexInfraError`.
3. **Actionable banner** (`pkg/processor/runner.go`): when a `CodexInfraError` reaches the runner, a multi-line banner prints the kind, matched stderr line, and recovery steps (e.g., `wsl --shutdown`, `docker system df`).

Exit behavior is unchanged, a codex failure still exits non-zero. The change is diagnostic visibility, not silent degradation.

What this does NOT fix:
- The underlying cause of EROFS in long-running Docker Desktop WSL2 containers. That remains a Docker/host issue. The fixes above catch it early (boot probe) or make it obvious when it fires mid-run (banner).

Workarounds that are no longer needed:
- Manually tailing claude progress to see why the run failed, the banner makes it obvious.
