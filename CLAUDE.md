# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a **documentation / notes repository**, not a software project. The goal stated in `README.md` is to capture the steps required to configure a Promise Pegasus R3 (Thunderbolt RAID enclosure) for use on Ubuntu 22 Linux desktop. There is no code, build system, package manifest, or test suite — only Markdown notes.

When the user asks to "run", "build", "lint", or "test", there is nothing to invoke; clarify or push back rather than inventing commands.

## Content layout

- `README.md` — one-line statement of intent.
- `boltctlMonitorOutput.md` — the working notebook. It interleaves:
  - Raw shell session captures (`boltctl monitor`, `boltctl enroll`, `lsblk`, `dmesg`, `parted`, `mkfs.ext4`) annotated with the device's Thunderbolt UUID `c9030000-0000-7d18-a271-27c448213116` and host disks (`nvme0n1`, `nvme1n1`, `nvme2n1`).
  - Prose explanations of each command's effect (what gets wiped, what gets written, alignment notes).
  - A worked example that destroys and recreates a GPT + ext4 filesystem on `/dev/sdb` labelled `pegasus_raid`.

New material should follow the same pattern: paste the actual command and its output, then explain what it did and why. Preserve real device IDs and `dmesg` lines verbatim — they are the evidence, not illustrative examples.

## Working with this repo

- Edits are almost always additions to `boltctlMonitorOutput.md` (or a sibling notes file). Prefer extending existing sections over creating new top-level files unless a clearly distinct topic warrants it.
- Commands documented here are **destructive** by design (`parted mklabel`, `mkfs.ext4`, etc.). When the user asks you to *execute* any of these against a real device, treat it as a high-risk action: confirm the target device path before running, and never guess which `/dev/sdX` is the Pegasus.


<!-- archon-rules-start -->
## Archon Knowledge Base — Ambient Behavio

Archon is a RAG knowledge management system connected via MCP (`archon` server). It provides semantic search across project documentation and shared cross-project knowledge. Use the `/archon-memory` skill for explicit operations.

### Session Start — Always Show Status
At the start of every session, check Archon state and display a **one-liner status** to the user:

1. Check if `.claude/archon-state.json` exists in the project
2. If yes, read it and note the Archon `project_id` and `source_id` for searches
3. Check doc freshness: compute MD5 hashes of docs vs stored hashes (use `md5sum <file> | cut -d' ' -f1` on Linux, `md5 -q` on macOS)
4. Display one of these status lines:

   - **Configured & fresh:** `Archon KB: <project> — <N> docs, synced <relative time>, up to date`
   - **Configured & stale:** `Archon KB: <project> — <N> docs, synced <relative time>, <N> files changed. Run /archon-memory sync`
   - **Not configured:** `Archon KB: not configured. Run /archon-memory ingest to set up.`
   - **Server unreachable:** `Archon KB: server unreachable — search unavailable this session`

This check should be quick (read state file + hash a few files). Do NOT call Archon APIs for this — just use local state.

### During Normal Work
- When needing project context (architecture, patterns, deployment, historic issues):
  PREFER `rag_search_knowledge_base(query, project_id)` over reading raw doc files
- Archon search is faster and uses less context than reading entire files
- Fall back to direct file reads only when Archon search returns no relevant results
- For code pattern questions, also try `rag_search_code_examples(query, project_id)`

### When Docs Are Modified
- If documentation files are modified during a session, Archon knowledge is stale
- Remind user to run `/archon-memory sync` before ending the session

### Cross-Project Knowledge
- Shared knowledge (framework docs, tool patterns) is available via `~/.claude/archon-global.json`
- Search shared KB: `rag_search_knowledge_base(query, project_id=shared_project_id)`
<!-- archon-rules-end -->
