# Document Local Docker Image vs Official Release Usage

## Overview

Add a short section to `CLAUDE.md` explaining how to run ralphex via Docker wrapper using a locally-built image (for dev iteration on ralphex itself) versus the official release from `ghcr.io`. This is operational documentation for ralphex contributors and power users who rebuild the image to test local changes.

## Context

The existing `CLAUDE.md` covers build commands, project structure, configuration, and workflow rules but does not document the local-vs-remote image decision. Users currently have to figure out the `RALPHEX_IMAGE` environment variable pattern by reading `scripts/ralphex-dk.sh` or `llms.txt`.

Relevant existing surfaces to reference:
- `RALPHEX_IMAGE` env var (default `ghcr.io/umputun/ralphex-go:latest`) - controls which image the wrapper pulls/uses
- `Dockerfile` (base) and `Dockerfile-go` (Go dev extension)
- Wrapper script: `scripts/ralphex-dk.sh`

## Success Criteria

- `CLAUDE.md` has a new short section titled "Running from Local Docker Image vs Official Release"
- The section lives under the existing "Docker Images" style area or near the existing "Project Structure" section, whichever fits better in narrative flow
- Contains two concrete command blocks: one for building and using a local image, one for pulling the official release
- Clarifies when to use which (dev on ralphex = local; consuming ralphex for other projects = release)
- Section is under 25 lines; terse, command-first

### Task 1: Add the section to CLAUDE.md

- [x] Open `CLAUDE.md` and find an appropriate insertion point (after "Build Commands" section is a natural fit, or before "Workflow Rules")
- [x] Add a new section with a heading like `## Running Locally vs Release` or `## Docker Image: Local Build vs Release`
- [x] Include a command block for building locally:
  ```bash
  docker build -t ralphex-local:dev .
  docker build -t ralphex-go-local:dev -f Dockerfile-go --build-arg BASE_TAG=dev .
  export RALPHEX_IMAGE=ralphex-go-local:dev
  ralphex docs/plans/feature.md
  ```
- [x] Include a note for using the official release:
  ```bash
  # default: wrapper pulls the latest published image automatically
  unset RALPHEX_IMAGE  # or leave unset
  ralphex docs/plans/feature.md
  ```
- [x] Add one sentence explaining the decision: local when iterating on ralphex itself, release when using ralphex to drive other projects
- [x] Keep the whole section under 25 lines
- [x] Stage and commit: `docs: document local Docker image vs release usage`

## Validation

- `git diff` shows only changes to `CLAUDE.md`
- The new section is readable and self-contained (no forward references to other sections that do not exist)
- Commit message is concise and follows the repo's existing commit style
