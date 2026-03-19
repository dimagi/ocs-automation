---
name: claude-code
description: Spawn and manage Claude Code sessions via ACP — covers full lifecycle (spawn, steer, cancel, resume), mode selection, workspace isolation with git worktrees, and task prompt guidance.
metadata: {"openclaw": {"requires": {"bins": ["acpx"]}, "always": false}}
---

# Claude Code (ACP)

Use this skill to run Claude Code as an ACP session. Claude Code sessions are isolated coding agents that work in their own git worktree.

## Spawning a session

1. Fetch the latest code from the base repo:
   ```bash
   git -C /workspace/app fetch origin
   ```

2. Create an isolated worktree for the session:
   ```bash
   git -C /workspace/app worktree add /workspace/sessions/<label> -b <branch-name> origin/main
   ```
   Use a short descriptive label (e.g., `fix-auth-bug`, `pr-1234-review`).

3. Spawn the ACP session using `sessions_spawn`:
   ```json
   {
     "task": "<clear description of what to do, including validation commands>",
     "runtime": "acp",
     "agentId": "claude",
     "cwd": "/workspace/sessions/<label>",
     "mode": "run",
     "streamTo": "parent",
     "thread": true
   }
   ```

### Mode selection

| Mode | When to use | Notes |
|------|-------------|-------|
| `"run"` | One-shot tasks: fix a bug, review a PR, run tests | Session closes when done |
| `"session"` | Interactive work: debugging, multi-step features | Requires `"thread": true` |

Set `"thread": true` when the user should be able to send follow-up messages to the session.

## Monitoring

- `/acp status` — check session state and runtime options
- The `streamLogPath` in the spawn response points to a JSONL log of progress updates
- For thread-bound sessions, streamed updates arrive in the bound thread
- Progress updates also stream to the parent conversation when `streamTo: "parent"` is set

## Steering

Redirect a running session without canceling it:
```
/acp steer --session <key> <instruction>
```
Example: `/acp steer --session agent:claude:acp:abc123 focus on the failing test first`

## Canceling and closing

- `/acp cancel <target>` — abort the current turn (session stays open for resume)
- `/acp close <target>` — end the session and unbind any thread

After closing, clean up the worktree:
```bash
git -C /workspace/app worktree remove /workspace/sessions/<label> --force
```
If the session pushed a branch with useful commits, verify the push completed before removing the worktree.

## Resuming a session

Continue where a previous session left off:
```json
{
  "task": "Continue — fix the remaining test failures",
  "runtime": "acp",
  "agentId": "claude",
  "resumeSessionId": "<previous-session-id>",
  "cwd": "/workspace/sessions/<label>"
}
```
The worktree must still exist at the original path. Useful for: interrupted work, handing off between operators, or gateway restarts.

## Writing effective task prompts

- State the objective in one sentence
- Name the repo, branch, and relevant files/directories if known
- Include validation commands (e.g., "run `pytest tests/auth/` to verify")
- Specify the deliverable: PR, commit, test results, or documentation
- Be specific — avoid "improve the code" or "clean up"
