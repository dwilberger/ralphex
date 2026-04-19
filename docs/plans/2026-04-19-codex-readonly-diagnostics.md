# Codex Read-Only Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail fast at container boot when `/home/app/.codex` is read-only, and classify codex infrastructure failures with a prominent, actionable error banner while preserving current non-zero exit behavior.

**Architecture:** Two independent surfaces:
1. `scripts/internal/init-docker.sh` — add a post-copy writability probe that exits non-zero before ralphex starts, saving hours of wasted claude work when the VM is in a bad state.
2. `pkg/executor/codex.go` + `pkg/processor/runner.go` — add a typed `CodexInfraError` for known infrastructure failures (read-only fs, disk full, session init). The runner renders a multi-line banner with cause + recovery steps, then returns the error as today so exit code stays non-zero.

**Tech Stack:** Go 1.26, testify, bash, golangci-lint, moq

**Context:** See `BUG-codex-readonly-fs.md` in repo root for full incident reports and error tails. This plan implements a combination of "fix #2" (boot-time detection) and a modified "fix #3" (better diagnostics, no silent pass).

## Success Criteria

- When `/home/app/.codex` is not writable after `cp -rL`, the container exits non-zero at init with a clear error message identifying probable causes.
- When codex stderr contains `Read-only file system`, `No space left on device`, or `Failed to (initialize|create) session`, ralphex emits a multi-line banner with kind, matched line, and recovery steps, then exits non-zero.
- When codex fails with an unknown error, existing behavior is preserved (current wrapped error message).
- `make test` and `make lint` pass.
- Manual Docker verification: container with a read-only `/home/app/.codex` aborts at boot, not after claude phases.

## File Structure

- `pkg/executor/codex.go` — add `CodexInfraError` type and `classifyCodexStderr()` helper; wire into `Run()` error path around line 175–185.
- `pkg/executor/codex_test.go` — table-driven tests for `classifyCodexStderr()` and end-to-end `Run()` with synthetic stderr.
- `pkg/processor/runner.go` — extend `handlePatternMatchError()` (or add a sibling) to detect `CodexInfraError` and render banner via `r.log.PrintRaw`.
- `pkg/processor/runner_test.go` — test that `CodexInfraError` produces the banner and is returned (non-nil) for the caller.
- `scripts/internal/init-docker.sh` — add ~10-line writability probe after the existing `chown -R app:app /home/app/.codex` on line 31.
- `BUG-codex-readonly-fs.md` — append a "Resolution" section pointing at this plan and the commits.

---

### Task 1: Add CodexInfraError type and classifier

**Files:**
- Modify: `pkg/executor/codex.go` (types section near top, around `PatternMatchError`/`LimitPatternError` in `executor.go:31-50`)
- Test: `pkg/executor/codex_test.go` (add at end)

Reasoning: follow the existing pattern of typed errors (`PatternMatchError`, `LimitPatternError`) so callers can use `errors.As`. The classifier is a pure function that scans stderr text for known infrastructure patterns — easy to test and extend.

- [ ] **Step 1.1: Write the failing classifier test**

Add to end of `pkg/executor/codex_test.go`:

```go
func TestClassifyCodexStderr(t *testing.T) {
	tests := []struct {
		name    string
		stderr  string
		wantKind string
		wantLine string // substring that must appear in CodexInfraError.Detail
	}{
		{
			name:     "read-only fs from skills manager",
			stderr:   "Reading prompt from stdin...\nERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)\n",
			wantKind: "readonly_fs",
			wantLine: "Read-only file system",
		},
		{
			name:     "read-only fs from models cache",
			stderr:   "ERROR codex_models_manager::cache: failed to write models cache: Read-only file system (os error 30)\n",
			wantKind: "readonly_fs",
			wantLine: "Read-only file system",
		},
		{
			name:     "session init failure (downstream of readonly)",
			stderr:   "Error: thread/start: thread/start failed: error creating thread: Fatal error: Failed to initialize session: Read-only file system (os error 30)\n",
			wantKind: "readonly_fs", // readonly_fs takes priority since the root cause is surfaced
			wantLine: "Read-only file system",
		},
		{
			name:     "session init without readonly",
			stderr:   "Error: thread/start failed: error creating thread: Fatal error: Failed to initialize session: some other reason\n",
			wantKind: "session_init",
			wantLine: "Failed to initialize session",
		},
		{
			name:     "disk full",
			stderr:   "ERROR codex_core::codex: write: No space left on device (os error 28)\n",
			wantKind: "disk_full",
			wantLine: "No space left on device",
		},
		{
			name:     "unknown error",
			stderr:   "some random error that is not infra related\n",
			wantKind: "",
		},
		{
			name:     "empty stderr",
			stderr:   "",
			wantKind: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			kind, detail := classifyCodexStderr(tc.stderr)
			assert.Equal(t, tc.wantKind, kind)
			if tc.wantLine != "" {
				assert.Contains(t, detail, tc.wantLine)
			}
		})
	}
}
```

- [ ] **Step 1.2: Run test to verify it fails**

Run: `go test ./pkg/executor/ -run TestClassifyCodexStderr -v`
Expected: FAIL with "undefined: classifyCodexStderr"

- [ ] **Step 1.3: Add CodexInfraError type and classifyCodexStderr in codex.go**

Add near the top of `pkg/executor/codex.go`, right after the imports and before `CodexStreams`:

```go
// CodexInfraError is returned when codex fails due to a known infrastructure issue
// (read-only filesystem, disk full, session init failure). Callers render a banner
// with recovery guidance and then return the error so exit code stays non-zero.
type CodexInfraError struct {
	Kind   string // "readonly_fs", "disk_full", "session_init"
	Detail string // stderr line that matched
	Inner  error  // underlying wait error, preserved for unwrap
}

func (e *CodexInfraError) Error() string {
	return fmt.Sprintf("codex infrastructure error (%s): %s", e.Kind, e.Detail)
}

func (e *CodexInfraError) Unwrap() error { return e.Inner }

// classifyCodexStderr scans codex stderr text for known infrastructure failure patterns.
// returns kind ("" if no match) and the matched line (for display to the user).
// readonly_fs takes priority over session_init because a failed session init rooted in
// a read-only filesystem should be reported as readonly_fs so the user fixes the real cause.
func classifyCodexStderr(stderr string) (kind, detail string) {
	for _, line := range strings.Split(stderr, "\n") {
		if strings.Contains(line, "Read-only file system") {
			return "readonly_fs", strings.TrimSpace(line)
		}
	}
	for _, line := range strings.Split(stderr, "\n") {
		if strings.Contains(line, "No space left on device") {
			return "disk_full", strings.TrimSpace(line)
		}
	}
	for _, line := range strings.Split(stderr, "\n") {
		if strings.Contains(line, "Failed to initialize session") ||
			strings.Contains(line, "Failed to create session") {
			return "session_init", strings.TrimSpace(line)
		}
	}
	return "", ""
}
```

- [ ] **Step 1.4: Run test to verify it passes**

Run: `go test ./pkg/executor/ -run TestClassifyCodexStderr -v`
Expected: PASS (all subtests)

- [ ] **Step 1.5: Commit**

```bash
git add pkg/executor/codex.go pkg/executor/codex_test.go
git commit -m "feat(executor): add CodexInfraError type and stderr classifier"
```

---

### Task 2: Wire classifier into CodexExecutor.Run

**Files:**
- Modify: `pkg/executor/codex.go:164-184` (the `switch` block that builds `finalErr` when `waitErr != nil`)
- Test: `pkg/executor/codex_test.go` (add after existing `TestClassifyCodexStderr`)

Reasoning: when codex exits non-zero and stderr shows an infra pattern, wrap the error as `CodexInfraError` so the runner can detect and render a banner. Non-infra non-zero exits keep today's behavior (`codex exited with error: ...\nstderr: ...`).

- [ ] **Step 2.1: Write the failing Run test**

Add to `pkg/executor/codex_test.go`:

```go
func TestCodexExecutor_Run_InfraError_ReadOnly(t *testing.T) {
	// simulate codex exiting non-zero with read-only fs in stderr
	stderrText := "Reading prompt from stdin...\n" +
		"2026-04-19T00:28:01.757560Z ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)\n"

	mock := &mocks.CodexRunnerMock{
		RunFunc: func(_ context.Context, _ string, _ ...string) (CodexStreams, func() error, error) {
			return CodexStreams{
				Stderr: strings.NewReader(stderrText),
				Stdout: strings.NewReader(""),
			}, func() error { return fmt.Errorf("exit status 1") }, nil
		},
	}
	e := &CodexExecutor{runner: mock}

	result := e.Run(context.Background(), "review please")

	require.Error(t, result.Error)
	var infraErr *CodexInfraError
	require.True(t, errors.As(result.Error, &infraErr), "expected CodexInfraError, got %T: %v", result.Error, result.Error)
	assert.Equal(t, "readonly_fs", infraErr.Kind)
	assert.Contains(t, infraErr.Detail, "Read-only file system")
}

func TestCodexExecutor_Run_NonInfraErrorPreserved(t *testing.T) {
	// unknown stderr: current wrapped error behavior is preserved (not CodexInfraError)
	stderrText := "some random codex failure\n"

	mock := &mocks.CodexRunnerMock{
		RunFunc: func(_ context.Context, _ string, _ ...string) (CodexStreams, func() error, error) {
			return CodexStreams{
				Stderr: strings.NewReader(stderrText),
				Stdout: strings.NewReader(""),
			}, func() error { return fmt.Errorf("exit status 1") }, nil
		},
	}
	e := &CodexExecutor{runner: mock}

	result := e.Run(context.Background(), "review please")

	require.Error(t, result.Error)
	var infraErr *CodexInfraError
	assert.False(t, errors.As(result.Error, &infraErr), "non-infra error should NOT be classified as CodexInfraError")
	assert.Contains(t, result.Error.Error(), "codex exited with error")
}
```

Ensure imports at top of test file include:

```go
import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/umputun/ralphex/pkg/executor/mocks"
)
```

(add any missing — keep existing imports.)

- [ ] **Step 2.2: Verify CodexRunnerMock exists**

Run: `ls pkg/executor/mocks/`
Expected: a file containing `CodexRunnerMock`. If it does not exist, run `go generate ./...` from repo root and re-check.

If the mock is missing, first inspect `pkg/executor/codex.go` for the `//go:generate moq` directive. If there is no directive for `CodexRunner`, add one near the top of `codex.go` (below imports):

```go
//go:generate moq -out mocks/codex_runner.go -pkg mocks -skip-ensure -fmt goimports . CodexRunner
```

Then run: `go generate ./pkg/executor/`

- [ ] **Step 2.3: Run tests to verify they fail**

Run: `go test ./pkg/executor/ -run TestCodexExecutor_Run_InfraError -v`
Expected: FAIL — `expected CodexInfraError, got ...`

- [ ] **Step 2.4: Update Run() in codex.go to wrap infra errors**

Edit `pkg/executor/codex.go` inside `CodexExecutor.Run()`. Find the block that builds `finalErr` when `waitErr != nil` (currently ~lines 164-184):

Replace:

```go
	case waitErr != nil:
		if ctx.Err() != nil {
			finalErr = fmt.Errorf("context error: %w", ctx.Err())
		} else {
			// include stderr tail for error context when codex exits with non-zero status
			if len(stderrRes.lastLines) > 0 {
				finalErr = fmt.Errorf("codex exited with error: %w\nstderr: %s",
					waitErr, strings.Join(stderrRes.lastLines, "\n"))
			} else {
				finalErr = fmt.Errorf("codex exited with error: %w", waitErr)
			}
		}
	}
```

With:

```go
	case waitErr != nil:
		if ctx.Err() != nil {
			finalErr = fmt.Errorf("context error: %w", ctx.Err())
		} else {
			stderrTail := strings.Join(stderrRes.lastLines, "\n")
			// classify known infrastructure failures (read-only fs, disk full, session init)
			// so the runner can render a banner with recovery guidance
			if kind, detail := classifyCodexStderr(stderrTail); kind != "" {
				finalErr = &CodexInfraError{Kind: kind, Detail: detail, Inner: waitErr}
			} else if stderrTail != "" {
				finalErr = fmt.Errorf("codex exited with error: %w\nstderr: %s", waitErr, stderrTail)
			} else {
				finalErr = fmt.Errorf("codex exited with error: %w", waitErr)
			}
		}
	}
```

- [ ] **Step 2.5: Run tests to verify they pass**

Run: `go test ./pkg/executor/ -v`
Expected: PASS (all tests, including existing ones)

- [ ] **Step 2.6: Commit**

```bash
git add pkg/executor/codex.go pkg/executor/codex_test.go pkg/executor/mocks/
git commit -m "feat(executor): classify codex infrastructure failures"
```

---

### Task 3: Render banner in runner when codex hits an infra error

**Files:**
- Modify: `pkg/processor/runner.go:1169-1185` (extend `handlePatternMatchError`)
- Test: `pkg/processor/runner_test.go` (add at end)

Reasoning: `handlePatternMatchError` already centralizes "log + return" behavior for typed errors. Adding a third branch for `CodexInfraError` keeps the pattern consistent. The banner is multi-line and visually distinct so it's impossible to miss in a log tail.

- [ ] **Step 3.1: Write the failing banner test**

Add to `pkg/processor/runner_test.go`:

```go
func TestRunner_HandlePatternMatchError_CodexInfraError_ReadOnly(t *testing.T) {
	logger := &mocks.LoggerMock{
		PrintFunc:    func(_ string, _ ...any) {},
		PrintRawFunc: func(_ string, _ ...any) {},
	}
	r := &Runner{log: logger}

	err := &executor.CodexInfraError{
		Kind:   "readonly_fs",
		Detail: "ERROR codex_core_skills::manager: failed to install system skills: io error while remove existing system skills dir: Read-only file system (os error 30)",
		Inner:  fmt.Errorf("exit status 1"),
	}

	got := r.handlePatternMatchError(err, "codex")

	require.Error(t, got)
	assert.Same(t, err, got, "handler must return the original error so exit code stays non-zero")

	// verify banner was rendered via PrintRaw
	rawCalls := logger.PrintRawCalls()
	require.NotEmpty(t, rawCalls, "expected a banner via PrintRaw")
	combined := ""
	for _, c := range rawCalls {
		combined += c.Format
	}
	assert.Contains(t, combined, "CODEX REVIEW FAILED")
	assert.Contains(t, combined, "readonly_fs")
	assert.Contains(t, combined, "Read-only file system")
	assert.Contains(t, combined, "wsl --shutdown") // recovery hint for readonly_fs
}

func TestRunner_HandlePatternMatchError_CodexInfraError_DiskFull(t *testing.T) {
	logger := &mocks.LoggerMock{
		PrintFunc:    func(_ string, _ ...any) {},
		PrintRawFunc: func(_ string, _ ...any) {},
	}
	r := &Runner{log: logger}

	err := &executor.CodexInfraError{
		Kind:   "disk_full",
		Detail: "write: No space left on device (os error 28)",
		Inner:  fmt.Errorf("exit status 1"),
	}

	got := r.handlePatternMatchError(err, "codex")

	require.Error(t, got)
	combined := ""
	for _, c := range logger.PrintRawCalls() {
		combined += c.Format
	}
	assert.Contains(t, combined, "disk_full")
	assert.Contains(t, combined, "docker system df") // recovery hint for disk_full
}

func TestRunner_HandlePatternMatchError_CodexInfraError_SessionInit(t *testing.T) {
	logger := &mocks.LoggerMock{
		PrintFunc:    func(_ string, _ ...any) {},
		PrintRawFunc: func(_ string, _ ...any) {},
	}
	r := &Runner{log: logger}

	err := &executor.CodexInfraError{
		Kind:   "session_init",
		Detail: "Failed to initialize session: some other reason",
		Inner:  fmt.Errorf("exit status 1"),
	}

	got := r.handlePatternMatchError(err, "codex")

	require.Error(t, got)
	combined := ""
	for _, c := range logger.PrintRawCalls() {
		combined += c.Format
	}
	assert.Contains(t, combined, "session_init")
	assert.Contains(t, combined, "codex /status") // recovery hint for session_init
}
```

Ensure imports include `"github.com/umputun/ralphex/pkg/executor"` and `"github.com/umputun/ralphex/pkg/processor/mocks"` (both are likely already present — keep existing imports).

- [ ] **Step 3.2: Verify LoggerMock has PrintRawFunc field**

Run: `grep -n "PrintRaw" pkg/processor/mocks/logger.go`
Expected: output showing `PrintRawFunc` field and `PrintRawCalls()` method. If missing, run `go generate ./pkg/processor/` to regenerate.

- [ ] **Step 3.3: Run tests to verify they fail**

Run: `go test ./pkg/processor/ -run TestRunner_HandlePatternMatchError_CodexInfraError -v`
Expected: FAIL — banner not rendered or error not returned.

- [ ] **Step 3.4: Extend handlePatternMatchError in runner.go**

Edit `pkg/processor/runner.go`. Locate `handlePatternMatchError` (around line 1171) and replace its body:

```go
// handlePatternMatchError checks if err is a PatternMatchError, LimitPatternError, or
// CodexInfraError and logs appropriate messages. Returns the error if it's a recognized
// typed error (to trigger graceful non-zero exit), nil otherwise.
func (r *Runner) handlePatternMatchError(err error, tool string) error {
	var patternErr *executor.PatternMatchError
	if errors.As(err, &patternErr) {
		r.log.Print("error: detected %q in %s output", patternErr.Pattern, tool)
		r.log.Print("run '%s' for more information", patternErr.HelpCmd)
		return err
	}
	var limitErr *executor.LimitPatternError
	if errors.As(err, &limitErr) {
		r.log.Print("error: detected %q in %s output", limitErr.Pattern, tool)
		r.log.Print("run '%s' for more information", limitErr.HelpCmd)
		return err
	}
	var infraErr *executor.CodexInfraError
	if errors.As(err, &infraErr) {
		r.renderCodexInfraBanner(infraErr, tool)
		return err
	}
	return nil
}

// renderCodexInfraBanner emits a multi-line, visually distinct banner describing a
// known codex infrastructure failure, the matched stderr line, and actionable recovery
// steps. Keeps exit behavior unchanged — the caller still returns a non-nil error so
// the run fails loudly.
func (r *Runner) renderCodexInfraBanner(e *executor.CodexInfraError, tool string) {
	const divider = "================================================================"
	r.log.PrintRaw("\n%s\n", divider)
	r.log.PrintRaw("CODEX REVIEW FAILED — INFRASTRUCTURE ERROR (%s)\n", e.Kind)
	r.log.PrintRaw("%s\n", divider)
	r.log.PrintRaw("tool: %s\n", tool)
	r.log.PrintRaw("matched: %s\n", e.Detail)
	r.log.PrintRaw("\nlikely cause and recovery:\n")
	switch e.Kind {
	case "readonly_fs":
		r.log.PrintRaw("  - Docker Desktop VM disk went read-only (corruption or mount failure)\n")
		r.log.PrintRaw("  - try: `wsl --shutdown` then restart Docker Desktop\n")
		r.log.PrintRaw("  - verify: `docker exec <container> dmesg | tail -30` should show EXT4-fs errors if corruption\n")
	case "disk_full":
		r.log.PrintRaw("  - Docker overlay or VM disk is full\n")
		r.log.PrintRaw("  - check: `docker system df` and `docker system prune`\n")
		r.log.PrintRaw("  - Docker Desktop > Settings > Resources > Virtual disk limit\n")
	case "session_init":
		r.log.PrintRaw("  - codex session init failed (non-readonly cause)\n")
		r.log.PrintRaw("  - check: `codex /status` on the host for auth/quota state\n")
		r.log.PrintRaw("  - verify: ~/.codex/auth.json is valid and not expired\n")
	}
	r.log.PrintRaw("\nclaude review work on the branch is preserved. run exits non-zero.\n")
	r.log.PrintRaw("%s\n\n", divider)
}
```

- [ ] **Step 3.5: Run tests to verify they pass**

Run: `go test ./pkg/processor/ -run TestRunner_HandlePatternMatchError -v`
Expected: PASS (all three subtests plus existing pattern-match tests).

- [ ] **Step 3.6: Run full processor tests to verify no regression**

Run: `go test ./pkg/processor/ -v`
Expected: PASS

- [ ] **Step 3.7: Commit**

```bash
git add pkg/processor/runner.go pkg/processor/runner_test.go
git commit -m "feat(runner): render banner for codex infra failures"
```

---

### Task 4: Boot-time writability check in init-docker.sh

**Files:**
- Modify: `scripts/internal/init-docker.sh` (extend the `if [ -d /mnt/codex ]; then` block)

Reasoning: baseimage runs `/srv/init.sh` before the main command and aborts the container if it exits non-zero. A simple `touch` probe after `cp -rL` + `chown` catches the read-only condition at boot, ~0 seconds into the run, instead of after hours of claude work.

- [ ] **Step 4.1: Modify init-docker.sh**

Edit `scripts/internal/init-docker.sh`. Replace the last block (currently lines 27–32):

```sh
# copy codex credentials if mounted
if [ -d /mnt/codex ]; then
    mkdir -p /home/app/.codex
    cp -rL /mnt/codex/* /home/app/.codex/ 2>/dev/null || true
    chown -R app:app /home/app/.codex
fi
```

With:

```sh
# copy codex credentials if mounted, then verify /home/app/.codex is writable.
# fail-fast avoids hours of wasted claude work when the container fs is read-only
# (Docker Desktop VM corruption, overlay exhaustion, host mount flakiness).
if [ -d /mnt/codex ]; then
    mkdir -p /home/app/.codex
    cp -rL /mnt/codex/* /home/app/.codex/ 2>/dev/null || true
    chown -R app:app /home/app/.codex

    # boot-time sanity check: codex requires write access at runtime
    probe=/home/app/.codex/.ralphex-write-check
    if ! touch "$probe" 2>/dev/null; then
        echo "ERROR: /home/app/.codex is not writable after setup" >&2
        echo "ERROR: codex review will fail; aborting container to avoid wasted work" >&2
        echo "possible causes:" >&2
        echo "  - Docker Desktop VM disk went read-only (try: wsl --shutdown; restart Docker Desktop)" >&2
        echo "  - container overlay layer exhausted (check: docker system df)" >&2
        echo "  - host mount flakiness (try: restart Docker Desktop)" >&2
        exit 1
    fi
    rm -f "$probe"
fi
```

- [ ] **Step 4.2: Verify script syntax**

Run: `bash -n scripts/internal/init-docker.sh`
Expected: no output (exit code 0).

- [ ] **Step 4.3: Smoke test the check with a writable dir (positive case)**

Create a temp simulation:

```bash
mkdir -p /tmp/rx-probe/codex /tmp/rx-probe/home-app
```

Run a modified probe manually:

```bash
probe=/tmp/rx-probe/home-app/.ralphex-write-check
touch "$probe" && echo OK && rm -f "$probe"
```

Expected: prints `OK`.

- [ ] **Step 4.4: Smoke test the check with a read-only dir (negative case)**

```bash
chmod 555 /tmp/rx-probe/home-app
probe=/tmp/rx-probe/home-app/.ralphex-write-check
if ! touch "$probe" 2>/dev/null; then echo FIRES; fi
chmod 755 /tmp/rx-probe/home-app
rm -rf /tmp/rx-probe
```

Expected: prints `FIRES`.

(Skip this step on Windows/Git Bash if `chmod 555` does not prevent root from writing — the real verification is Task 6.)

- [ ] **Step 4.5: Commit**

```bash
git add scripts/internal/init-docker.sh
git commit -m "feat(docker): fail fast when /home/app/.codex is not writable"
```

---

### Task 5: Document resolution in BUG-codex-readonly-fs.md

**Files:**
- Modify: `BUG-codex-readonly-fs.md` (append a section)

Reasoning: the bug file remains in the repo as historical context. Appending a "Resolution" section makes it clear which incident this plan addresses and what behavior changed, so future readers don't treat it as open.

- [ ] **Step 5.1: Append resolution section**

Open `BUG-codex-readonly-fs.md` and append at the very end:

```markdown

## Resolution (2026-04-19)

Implemented per `docs/plans/2026-04-19-codex-readonly-diagnostics.md`:

1. **Boot-time probe** (`scripts/internal/init-docker.sh`): container aborts at init when `/home/app/.codex` is not writable after `cp -rL`. Saves hours of wasted claude work when Docker Desktop VM is in a bad state.
2. **Error classification** (`pkg/executor/codex.go`): codex stderr is scanned for `Read-only file system`, `No space left on device`, and `Failed to (initialize|create) session`. Matches produce a typed `CodexInfraError`.
3. **Actionable banner** (`pkg/processor/runner.go`): when a `CodexInfraError` reaches the runner, a multi-line banner prints the kind, matched stderr line, and recovery steps (e.g., `wsl --shutdown`, `docker system df`).

Exit behavior is unchanged — a codex failure still exits non-zero. The change is diagnostic visibility, not silent degradation.

What this does NOT fix:
- The underlying cause of EROFS in long-running Docker Desktop WSL2 containers. That remains a Docker/host issue. The fixes above catch it early (boot probe) or make it obvious when it fires mid-run (banner).

Workarounds that are no longer needed:
- Manually tailing claude progress to see why the run failed — the banner makes it obvious.
```

- [ ] **Step 5.2: Commit**

```bash
git add BUG-codex-readonly-fs.md
git commit -m "docs: record resolution for codex readonly-fs incident"
```

---

### Task 6: End-to-end verification

**Files:** none (verification only)

Reasoning: project CLAUDE.md mandates a toy-project e2e run after any code change. Since this change affects the docker wrapper path too, also do one targeted manual check of the boot probe.

- [ ] **Step 6.1: Run full test suite**

Run: `make test`
Expected: all tests pass; coverage unchanged or improved.

- [ ] **Step 6.2: Run linter**

Run: `make lint`
Expected: clean.

- [ ] **Step 6.3: Cross-compile for Windows to verify no portability regressions**

Run: `GOOS=windows GOARCH=amd64 go build ./...`
Expected: no errors.

- [ ] **Step 6.4: Toy project e2e (sanity check — no readonly repro required)**

From repo root:

```bash
./scripts/internal/prep-toy-test.sh
cd /tmp/ralphex-test
go run <ralphex-repo>/cmd/ralphex docs/plans/fix-issues.md
```

Expected: normal task → claude review → codex review → completed flow. No banner (happy path).

- [ ] **Step 6.5: Targeted boot probe test**

Rebuild the image locally so the new init-docker.sh is baked in, then run:

```bash
docker build -t ralphex-test:probe .
MSYS_NO_PATHCONV=1 docker run --rm \
  -v //c/Users/Daniel/.codex://mnt//codex:ro \
  ralphex-test:probe sh -c "ls /home/app/.codex/.ralphex-write-check 2>&1 | head -1"
```

Expected: `ls: /home/app/.codex/.ralphex-write-check: No such file or directory` (probe file cleaned up after success).

To confirm the failure path, force read-only by stacking a read-only mount on top of the writable dest (requires `--user 0` and then `chmod -w`). Skip if hard to reproduce — the code path is unit-tested indirectly via inspection of `touch` exit code.

- [ ] **Step 6.6: Final commit if any fixup needed**

If any of the above surfaced issues, fix them and commit:

```bash
git add -p
git commit -m "fix: <describe>"
```

---

## Self-Review Notes

- All code steps contain actual code blocks (no "add validation" hand-waves).
- Error type names match across tasks: `CodexInfraError` (defined Task 1, used Tasks 2 and 3).
- Function `classifyCodexStderr` is defined in Task 1.3 and used in Task 2.4 — naming consistent.
- Kind strings (`readonly_fs`, `disk_full`, `session_init`) match across classifier, tests, and banner switch.
- Commit messages follow the repo convention (`feat(scope):`, `docs:`).
- Spec coverage: boot probe (Task 4), error classification (Tasks 1–2), banner (Task 3), historical record (Task 5), verification (Task 6). No gaps.
