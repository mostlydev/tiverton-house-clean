# Storage Layout

This document defines the logical storage surfaces for the pod.

## Goal

Keep desk state split by ownership:
- shared desk surface for news, research, reports, logs, cache, and public exports
- private per-agent surfaces for session memory and ticker notes
- API-owned trading state for watchlists, positions, wallets, and workflow

## Shared Surface

Shared data that more than one agent or service should read belongs here.

| Runtime path | Repo mirror | Purpose |
|---|---|---|
| `<repo-root>/storage/shared/news` | `storage/shared/news` | routed news files, summaries, latest desk feed |
| `<repo-root>/storage/shared/research/tickers` | `storage/shared/research/tickers` | desk-visible research artifacts used for proposal gating and dashboard views |
| `<repo-root>/storage/shared/reports` | `storage/shared/reports` | pre-market and end-of-day reports |
| `<repo-root>/storage/shared/logs` | `storage/shared/logs` | floor sync and operator-visible logs |
| `<repo-root>/storage/shared/public` | `storage/shared/public` | staging area for public exports |

## Private Directories

Each agent keeps its own working files on private surfaces.

| Runtime path | Repo mirror | Purpose |
|---|---|---|
| `<repo-root>/storage/private/<agent>/memory/session.md` | `storage/private/<agent>/memory/session.md` | current session plan and open follow-ups |
| `<repo-root>/storage/private/<agent>/notes/*.md` | `storage/private/<agent>/notes/*.md` | ticker- or event-specific notes not yet promoted to shared research |

## Ownership Model

Logical ownership:
- shared research and reports belong on the shared surface
- session notes belong in private memory
- ticker notes belong in private notes
- watchlists and positions belong in `trading-api`

## Preparation Status

Prepared in this repo:
- shared and private directory placeholders exist under `storage/`
- pod env names exist for shared and private roots
- scripts and `trading-api` use env-driven roots for research and private notes

Operating rule:
- do not create file mirrors for watchlists or positions
- use notes for human reasoning, and the API for desk state
