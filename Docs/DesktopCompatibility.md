# Desktop compatibility research and proof procedure

Baseline recorded September 30, 2026. This is supporting evidence for [the build plan](../BUILD_PLAN.md), not a record of passing desktop integration tests. No native thread was created, prompted, or modified for this research.

## Installed applications

Versions below were read from application bundle metadata. App version and embedded agent/runtime version must both be captured in future compatibility runs; they are different identifiers.

| App | Bundle identifier | Desktop version | Build |
|---|---|---|---|
| Codex, installed as `ChatGPT.app` | `com.openai.codex` | 26.928.21956 | 12404 |
| Cursor | `com.todesktop.230313mzl4w4u92` | 3.23.10 | 3.23.10 |
| Claude Desktop | `com.anthropic.claudefordesktop` | 2.16120.0 | 2.16120.0 |
| Orca, UX reference | `com.stablyai.orca` | 1.4.218 | 1.4.218 |

The separately installed Codex CLI reported 0.150.1 and Cursor CLI reported 2026.09.23-86fc751. These versions do not certify the corresponding desktop app.

## Candidate paths

| Surface | Primary experiment | Fallback experiment | Unproved release requirement |
|---|---|---|---|
| Codex desktop local thread | Agent-facing MCP/plugin plus trusted enrollment and lifecycle observation; investigate a documented desktop control route. | Exact-thread Accessibility navigation/submission with native-event confirmation. | External control of the actual native thread, idle wake, native worker creation, and account isolation. |
| Cursor IDE local Agent thread | Companion extension registers MCP/plugin/hooks; bind native conversation and observe lifecycle. | Exact-thread Accessibility submission; stop-hook delivery only for an already active turn boundary. | Arbitrary existing-thread control, idle wake, and native creation confirmation. |
| Cursor Agents Window local thread | Repeat the IDE experiment independently and determine whether identifiers/storage/control are shared. | Versioned Accessibility adapter specific to this surface. | Same native identity across selection, reopen and external continuation. |
| Claude Desktop local Code session | Capture documented inbox discovery through a supported hook; establish Desktop applicability and the message/receipt contract. | Exact Code-thread Accessibility navigation/submission. | Reliable native endpoint identity, idle inbound delivery, thread creation and native return. |

No row is certified. General desktop navigation, CLI resume, a model using MCP, and native-thread control are separate capabilities.

## Evidence boundaries

**Codex.** App-hosted tools available in this environment operate native chats. Inspection of the bundled tool bridge shows it depends on host-supplied context; Shastra must not reuse its internal pipe. The public [MCP configuration](https://learn.chatgpt.com/docs/extend/mcp) and [plugin packaging](https://developers.openai.com/plugins/build/plugins) docs establish a route for exposing Shastra tools inside the agent. [App-server](https://learn.chatgpt.com/docs/app-server) establishes an embedding protocol, not external desktop attachment. [Hooks](https://learn.chatgpt.com/docs/hooks) are candidate lifecycle input; distinguish parent session identity from native thread identity and active-turn delivery from idle wake.

**Cursor.** [Official support](https://forum.cursor.com/t/local-ide-agent-chats-and-the-agent-cli-still-use-separate-session-stores/165486/8) reports separate local IDE and CLI/SDK stores. The [extension API](https://cursor.com/docs/extension-api) documents MCP/plugin registration. [Hooks](https://cursor.com/docs/hooks) expose conversation/generation identity, workspace and transcript metadata; stop follow-ups can continue work at a boundary. These do not establish arbitrary idle local-thread submission. [Deep links](https://cursor.com/docs/reference/deeplinks) prefill prompts rather than proving execution. The [SDK](https://cursor.com/docs/sdk/typescript) is a separate integration whose local sessions must not be presumed to be desktop threads.

**Claude.** [Desktop Code documentation](https://code.claude.com/docs/en/desktop) covers native session collaboration and cross-surface continuation. Its CLI-import flow is not the test for controlling an existing Desktop thread. [Session messaging](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket) documents socket discovery and authentication for hooks/scripts; prove the installed desktop path and complete wire contract. [Desktop links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link) distinguish starting Code work from opening a Chat conversation. Neither is proof of opening an arbitrary existing local Code session.

## Minimum experiment

Use one disposable Git project and a native desktop-created thread per surface. No tests should operate on a valuable existing user conversation. A test prompt should have a unique operation marker and a harmless, deterministic goal, such as creating a specifically named fixture file and reporting its contents.

1. Record app build, surface, actual runtime build if exposed, account label, workspace, and baseline native ID. Do not store credentials in the evidence bundle.
2. Enroll that exact endpoint through trusted metadata or a one-use nonce verified in its native turn. Exercise a second caller to establish that it cannot claim the first endpoint.
3. Read/import available history and record completeness and source cursor. Prove that the workspace is resolved rather than inferred as the user's home directory.
4. Write a dispatch intent to the test operation journal, submit once through the candidate desktop route, and capture a native receipt or observed turn.
5. Verify the same native ID in the original app, the expected fixture result, and that the relevant app-specific tool set remains present.
6. Type a follow-up directly in the native app. Verify Shastra observes it once, with correct provenance and without replacing prior history.
7. Repeat the send while the thread is idle, running, and not selected. Preserve a draft in the native composer during one case.
8. Disconnect immediately after submission and before receipt; reconcile rather than resubmitting. Repeat for native worker creation, where supported.
9. Restart Shastra and the native app; verify identity and history reconciliation. Do not assume a desktop process restart preserves an active turn.
10. Revoke or lose the connection/UI capability and verify that the adapter reports the specific limitation without launching a substitute CLI session.

Steps 1–6 are the first vertical-slice gate. Steps 7–10 and native creation/idle wake are separate capabilities that must pass before their corresponding product promises are enabled. A failure on one app does not prevent building a verified slice on another.

## Result record

Every probe writes a structured, redacted record with:

- Test ID, date, app/surface/build, runtime build, adapter revision and fixture revision.
- Native endpoint/store identity and observed account reference; avoid user-visible email in exported diagnostics.
- Requested operation, operation ID, expected native revision and delivery policy.
- Evidence kind and location: native event/receipt, source delta, or UI observation.
- Outcome: `verified`, `documentedUnverified`, `unsupported`, `temporarilyUnavailable`, or `unknown`.
- Native acknowledgement, final source cursor, history completeness and retained app capabilities.
- Failure stage, retry/reconciliation outcome, user intervention required and next experiment.

Promote each capability independently. `openExactThread` does not imply `sendExistingThread`; `sendExistingThread` does not imply `wakeIdleThread`; a successful turn does not prove multi-account isolation. A reliable foreground UI path may be supported with an explicit unlocked-desktop requirement, while headless delivery remains unavailable.

## Initial stopping decisions

If stable endpoint binding cannot be established, stop automatic dispatch for that surface. If sending is accepted but not reconcilable after a lost receipt, retain `unknown` and do not retry automatically. If only a prepared-message/deep-link flow works, offer it honestly as assisted continuation; it does not pass unattended delegation. If multiple native desktop accounts cannot be isolated, keep simultaneous desktop-account selection unavailable while retaining the separate managed-runtime option.

Choose the first production vertical slice from the evidence, not from provider preference. Keep every unmet original desktop requirement in the release checklist.

## September 30 implementation probe

[Structured evidence](Probes/2026-09-30-desktop.json) records a limited live experiment and the blockers. **The minimum P0 gate has not passed.** No production desktop send capability is enabled.

Cursor Agents Window accepted two harmless, tool-free turns in a disposable native conversation. The second turn remembered the first acknowledgement. Read-only source observation found both turns and replies under native ID `68f6c99a-c31a-4680-a4d6-3b068797a037`. The new Shastra observer loaded all four messages in order, deduplicated a repeated read, and retained their IDs after SQLite reopen. This used the existing Test workspace, not an isolated proof project, and the test operator's computer-use tool rather than a Shastra-owned delivery driver. It proves a candidate UI path and working source observation, not complete enrollment, account binding, or autonomous dispatch.

Codex UI inspection was rejected by the computer-use tool for safety reasons; no bypass was attempted. Claude's installed account exposes a Free plan and the Code tab presents Get Claude Code, so no Desktop Code session was available. Cursor IDE was not separately certified. Native-specific tools, account separation, competing drafts, idle parent wake, crash ambiguity, and second-caller isolation remain open gates.

Run the read-only observation regression against the retained disposable Cursor chat:

```sh
swift run ShastraSelfTest --cursor-observe 68f6c99a-c31a-4680-a4d6-3b068797a037
```

This command writes only a temporary Shastra database and prints no private conversation contents. It expects the four fixture messages and intentionally fails if the fixture changes. It cannot certify the desktop send path.
