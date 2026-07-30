# Server Build Artifact Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build deployable server artifacts in GitHub Actions and deploy them without compiling on production.

**Architecture:** A manually triggered workflow produces one tarball. A local deployment script validates that tarball, backs up SQLite, swaps only compiled directories, restarts systemd, and rolls back on failure.

**Tech Stack:** GitHub Actions, pnpm 10.6.0, Node.js 24, Bash, systemd, SQLite

## Global Constraints

- Never compile TypeScript or Vite on the production server.
- Never alter `.env` or remove untracked user data.
- Back up and validate SQLite before replacing build artifacts.
- The GitHub workflow must not connect to production automatically.

---

### Task 1: Cloud build artifact

**Files:**
- Create: `.github/workflows/server-build-artifact.yml`

**Interfaces:**
- Consumes: repository source and `pnpm-lock.yaml`
- Produces: `ai-novel-server-<commit>.tar.gz`

- [ ] Add a manual-only workflow using Node.js 24 and pnpm 10.6.0.
- [ ] Run `pnpm install --frozen-lockfile` and `pnpm build` on the hosted runner.
- [ ] Stage only runtime build directories, Prisma metadata, and package manifests.
- [ ] Assert required artifact files before upload.

### Task 2: Safe production deployer

**Files:**
- Create: `scripts/deploy-server-artifact.sh`

**Interfaces:**
- Consumes: a local artifact path
- Produces: updated compiled directories or a restored previous version

- [ ] Validate arguments, archive paths, required files, tools, and service name.
- [ ] Implement `--verify-only` without modifying the installation.
- [ ] Back up SQLite with `.backup` and `quick_check`.
- [ ] Stage old directories, install new directories, restart, and health-check.
- [ ] Restore staged directories and restart on any post-swap failure.

### Task 3: Verification and documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/releases/release-notes.md`

- [ ] Run `bash -n scripts/deploy-server-artifact.sh`.
- [ ] Verify a malformed fixture fails and a complete fixture passes.
- [ ] Parse the workflow YAML and inspect trigger/commands.
- [ ] Document the server deployment command and user-visible low-memory improvement.
- [ ] Commit the verified change.

