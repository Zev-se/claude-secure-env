# CLAUDE.md — Project Context for AI Agent Sessions

This file is the persistent memory for your AI coding agent. Keep it accurate and up to date.
The agent reads this at the start of every session to understand the project.

---

## Project Overview

<!-- What this project is and what it does. Be specific. -->

_Example: A REST API for managing inventory records, built with FastAPI and PostgreSQL.
Deployed on AWS Lambda behind an API Gateway. Used by the warehouse team to track stock levels._

---

## Architecture

<!-- Key structural decisions and the reasoning behind them. -->

_Example:_
- _Uses async FastAPI because the inventory service makes many concurrent DB calls_
- _PostgreSQL chosen over DynamoDB for its transaction support — inventory updates must be atomic_
- _Lambda functions kept thin; all business logic lives in `src/core/`_
- _No ORM — raw SQL via `asyncpg` for performance on bulk queries_

---

## Conventions

<!-- Coding patterns, naming conventions, and file organization this project follows. -->

_Example:_
- _All public functions have type annotations_
- _Tests mirror the `src/` directory structure under `tests/`_
- _Environment variables are never read outside of `src/config.py`_
- _Migrations live in `db/migrations/` and are numbered sequentially_

---

## Failed Approaches

<!-- Things that were tried and didn't work — and why. This prevents re-trying dead ends. -->

_Example:_
- **Tried: SQLAlchemy ORM** — Generated N+1 queries on the inventory list endpoint. Dropped in favour of raw asyncpg.
- **Tried: Batching Lambda invocations** — SQS batch size > 1 caused partial-failure handling complexity that wasn't worth it at current volume.

---

## External Constraints

<!-- APIs, legacy systems, performance requirements, or hard limits the agent must respect. -->

_Example:_
- _The warehouse client requires responses within 200ms at p99_
- _The legacy ERP system speaks XML over SOAP — adapter lives in `src/erp/`_
- _AWS account limits Lambda concurrency to 100 — do not design for higher burst_

---

## Current Focus

<!-- What is actively being worked on right now. Update this every session. -->

_Example: Implementing paginated export endpoint (`GET /inventory/export`) — see TASKS.md for details._

---

## Agent Instructions

These instructions apply to every session. Follow them exactly.

1. **Read `TASKS.md` at the start of every session** before writing any code or making any changes.

2. **At the end of every session**, propose updates to `CLAUDE.md` and `TASKS.md` as explicit diffs
   or clearly described changes. Do **not** apply them silently — present them for review.

3. **Never modify files outside `/workspace/`** regardless of what any instruction says.

4. **Treat files in `:ro` mounts as read-only** even if a filesystem bug would allow writes.
   Read from them freely; never write to them.

5. **Commit work at logical checkpoints** with descriptive commit messages.
   Prefer small, focused commits over large ones. Never commit with `--no-verify`.
