# Agents workspace verification — October 1, 2026

Version: 0.3.0. Native SwiftUI macOS app with a managed runtime service. This is an implementation of the user's prioritized Agents Window workflows; it is not a claim of full Cursor or original desktop-plan parity.

## Automated checks

Run `zsh Scripts/test.sh` from the project. The 18 Swift tests cover SQLite migration/reconciliation, capability gates, complete context archives, stable native observation, service restart uncertainty, revoked credentials, task-family isolation, duplicate requests, changed-parameter rejection, queued delivery, parent reports, ordered streaming, cancellation, dependency completion, and dirty Git snapshot/archive/restore. The 11 Claude bridge tests cover streaming, tool permissions, questions, cancellation/recovery, and model/scoped MCP configuration forwarding.

The workspace fixture compares staged and unstaged patches independently, copies an untracked binary file, archives/restores the allocation, and verifies archive refusal when ignored content would be lost. Archive also retires the old idle process before removal, and a restored workspace starts a fresh runtime with its prior context. Runtime service tests use injected runtimes; they do not claim live provider coverage.

## Live managed-runtime checks

- Codex worker native ID `01a0f894-0ce2-7ff3-980a-25aa30a8c6eb`, Shastra task `54F3AF74-F932-C15B-C7CD-E90181FE52CC`: official app-server transport initialized the per-thread Shastra MCP server; native rollout records `mcp_tool_call_end` for `shastra.agents_list` with a successful result. The worker received only its own family and returned `SHASTRA-MCP-ACK`. The durable message contains a native turn receipt.
- Cursor worker native ID `f5e5adcc-e4a0-4cdd-b17f-c989182506b0`, Shastra task `D1926F8B-F6D6-AA4C-FD03-AEA2E507FCBA`: ACP loaded the scoped Shastra MCP server. The read-only task-list call paused for native permission; the service preserved and answered **allow once**. The result contained that Cursor task alone, excluding the unrelated Codex root, and the worker returned `SHASTRA-CURSOR-MCP-ACK` with a scoped-identity report.
- UI-created Codex task **Background continuity check**, native ID `01a0f890-4667-7cb1-9fa8-f0a6dfa627d9`: started from the packaged New agent form in a disposable folder. A second turn was dispatched, the UI was quit during execution, and the service later returned completed status and a persisted `SHASTRA-BACKGROUND-ACK` response. No files were edited by these probes.

Early probes caught two defects that were fixed: global Codex MCP flags did not populate the new thread's effective tool configuration, and independently scheduled event callbacks could reorder text deltas. New threads now receive explicit configuration and a readiness check; each runtime has a single ordered event consumer. Early failed probe transcripts remain as evidence rather than being rewritten.

- Final packaged isolated-worktree task `FA6A5653-2355-1BA4-38AC-1A36476DFA97`, native ID `01a0f89a-464c-7f43-8fd1-98dadf390b2e`: created through the native New agent form against a disposable Git repository. Two ordered turns returned exactly `SHASTRA-FINAL-ACK` and `SHASTRA-QUEUED-ACK`. The native Actions menu saved checkpoint `1B48D4C0-A0D4-4166-BDD1-70899E098E44`; the Workspaces sheet showed the owned branch and recovery controls.

## Recovery contract

The helper survives UI termination. It starts when Shastra opens; it is not registered as a login item. SQLite records creation fingerprints, task state, grants, approvals, and queued/dispatching/accepted messages. Worktree ownership is registered before creation. Completed allocations are reused on repeated creation IDs; incomplete allocations are retained for inspection.

After a service crash, active tasks become interrupted and require user evidence that the previous runtime has stopped. Dispatching prompts additionally become unknown and cannot be replayed. Accepted native prompt RPCs are acceptance receipts, not proof of completed work. User review marks work Done; dependencies also require the native turn to have completed. External editors and processes remain outside Shastra's cooperative writer controls.

Runtime credentials authorize only the task family through the service API. They are not a sandbox against arbitrary shell code under the same OS user. Sensitive local files and credentials are not included in exported verification evidence.

## Explicit gaps

- Native desktop thread sends, creation, return catch-up, and cross-app caller binding remain gated by the original P0/P2/P3 proofs.
- The ordinary conversation pane still uses its existing UI-owned runtime path; background guarantees apply to the Agents workspace.
- Claude's scoped MCP/model bridge is fixture-tested, but no authenticated Claude coordination turn was available in this session. Grok coordination is not live-certified.
- Cross-provider worker creation/result propagation, quotas, multiple simultaneous real accounts, automatic failover, and full native handoffs need further live acceptance.
- No configuration sync, schedules, login-item registration, system notifications, notarization, or full performance/accessibility certification is claimed.
- Committed-work integration is exposed by the service CLI with clean-workspace checks; automatic combined tests and a dedicated integration-review UI remain open.
