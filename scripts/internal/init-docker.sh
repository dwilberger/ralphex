#!/bin/sh
# init script for ralphex docker container
# baseimage runs /srv/init.sh if it exists before the main command

# copy only essential claude files (not the entire 2GB directory)
if [ -d /mnt/claude ]; then
    mkdir -p /home/app/.claude
    # copy config files only (not cache, history, debug, todos, etc.)
    for f in .credentials.json settings.json settings.local.json CLAUDE.md format.sh; do
        [ -e "/mnt/claude/$f" ] && cp -L "/mnt/claude/$f" "/home/app/.claude/$f" 2>/dev/null || true
    done
    # copy essential directories (symlinked in dotfiles setups)
    for d in commands skills hooks agents plugins; do
        [ -d "/mnt/claude/$d" ] && cp -rL "/mnt/claude/$d" "/home/app/.claude/" 2>/dev/null || true
    done
    chown -R app:app /home/app/.claude
fi

# copy credentials extracted from macOS keychain (mounted separately)
if [ -f /mnt/claude-credentials.json ]; then
    mkdir -p /home/app/.claude
    cp /mnt/claude-credentials.json /home/app/.claude/.credentials.json
    chown -R app:app /home/app/.claude
    chmod 600 /home/app/.claude/.credentials.json
fi

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
