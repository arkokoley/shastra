# Implementation status

Audit against `/Users/arkokoley/Downloads/PLAN.md`, updated October 1, 2026. The user prioritized Agents Window workflows for this implementation pass.

The milestone table below records the original plan's implementation status. The revised [desktop continuity build plan](BUILD_PLAN.md) now governs future work: existing desktop threads must remain usable in their original apps, with verified native round trips and cross-app coordination. Current subprocess transports and history imports do not satisfy that desktop gate. [Compatibility research](Docs/DesktopCompatibility.md) records the live probe and remaining integration gaps; the durable identity foundation is implemented below, while the native desktop gate remains open.

**The plan is not complete.** Shastra is a usable native prototype with substantial daily-use functionality. No milestone is claimed complete while its exit conditions remain unproved.

| Milestone | Status | Implemented | Missing exit conditions |
|---|---|---|---|
| 1. Integration proof | Partial | Codex app-server, Cursor/Grok ACP; official Claude SDK bridge; streaming, approvals, Claude questions and cancellation; account profiles | Authenticated Claude turns/tools/resume; two simultaneous real accounts per original provider; safe native resume proof |
| 2. Personal daily use | Partial | Automatic local discovery; projects with nested worktrees; linked continuations; accounts; native files/images/PDFs/terminal/browser/diffs; keyboard Quick Open; managed worktree allocation/checkpoint/archive/restore | Indexing unvisited native histories; project settings/source health; full workflow acceptance |
| 3. Coordination | Partial | Managed worker chats, scoped MCP/CLI, task board, dependencies, durable follow-ups, parent reports, inbox, side chats | Native desktop workers, cross-app handoffs, cross-review acceptance and complete return-to-source proof |
| 4. Unattended execution | Partial | Packaged background service for Agents workspace; durable queues, UI-close continuity, restart ownership/delivery gates, bounded account/workspace concurrency | SMAppService registration, sleep/update reconciliation, schedules, quota waiting, failover and system notifications |
| 5. Setup portability | Pending | Native vendor processes read their supported local settings | Three-way configuration reconciliation/rollback, setup checks, OpenCode/Hermes/custom ACP registration |
| 6. Hardening | Partial | Protocol/history/account/terminal/worktree fixtures; ad-hoc signed local app; accessible native controls | Native crash reconciliation, 10 streams/10,000-message performance, comprehensive accessibility/diagnostics, distribution signing |

## September 30 continuity implementation

- P0 is **partial, not passed**. A disposable Cursor Agents Window chat completed two native turns, and Shastra independently observed/deduplicated their four messages. Codex GUI access was denied by the computer-use tool. Claude Desktop Code was unavailable on the signed-in Free account. Cursor IDE remains separately unverified. See [probe evidence](Docs/Probes/2026-09-30-desktop.json).
- P1 core is implemented: pinned GRDB, transactional JSON migration and metadata backup, stable logical IDs, multiple namespaced native endpoints, legacy provenance preservation, append-preserving observation, event revisions, FTS5, context archives, durable delivery state, and restart reconciliation to unknown. Drafts persist with their conversations.
- App wiring retains source IDs across managed runtime changes, refreshes the original source independently, displays endpoint lineage, requires an explicit linked-runtime choice for imported chats, and blocks unresolved workspaces or uncertain delivery. Native desktop control is not advertised.
- The desktop adapter contract and in-process coordinator enforce build-specific proof, thread/account/workspace binding, source revision, draft preservation, activity capabilities, receipts, and no replay of uncertain operations. No production desktop adapter is certified or installed. Managed runtime successes do not promote desktop capabilities.
- Corrected Cursor's ISO timestamp parsing and added stable native item IDs to Cursor/Codex/Claude observations. The app no longer replaces a logical conversation's entries on source refresh.

## Verification

- `swift test --enable-swift-testing`: 10 passing fixtures covering migration and rollback, identity/refresh, FTS, delivery recovery/deduplication, lost receipts, capability gates, and large context preservation.
- `swift run ShastraSelfTest`: existing history, RPC lifecycle, persistence and local Codex history checks pass.
- `swift run ShastraSelfTest --accounts`: synthetic account isolation and sign-in lifecycle checks pass.
- `swift run ShastraSelfTest --workspace-identity`: existing workspace identity checks pass.
- `swift run ShastraSelfTest --cursor-observe 68f6c99a-c31a-4680-a4d6-3b068797a037`: live native observation, repeated refresh, and SQLite reopen pass. This is not a Shastra desktop-send test.
- `npm test` in `Bridge/Claude`: all 10 bridge fixtures pass.
- Packaged app 0.2.0 launches, migrates 1,195 existing conversations with the original JSON backup retained, and shows the Cursor probe and source endpoint. Live SQLite integrity and foreign-key checks pass.
- Final packaged app restart restored the unsent verification draft, four native source messages, managed reply, selected chat, and both endpoint identities. The test draft was then cleared. The app remains open on the disposable probe.
- A live linked Codex runtime turn in the disposable probe's logical conversation correctly recalled both native Cursor acknowledgements. SQLite contains an accepted RPC receipt and preserves the original Cursor endpoint alongside the new managed endpoint. This proves managed context transfer, not a desktop round trip.

## Remaining release gates

P0 still needs trusted per-thread caller binding, a Shastra-owned delivery route, current account/workspace verification, and a complete original-app round trip. Codex requires an allowed supported integration route; Claude requires an available Code-enabled session. The proven Cursor UI path needs binding, draft/identity guards, navigation, and receipt-loss experiments before it can become a production adapter.

P2–P8 remain open as complete milestones: certified desktop adapters, native cross-app handoffs/catch-up, desktop caller enrollment, multi-account desktop eligibility/failover, configuration sync, service lifecycle hardening, and daily-use acceptance. Managed MCP delegation, workspace lifecycle, and background execution are now implemented but do not satisfy native desktop exit conditions. The app does not silently substitute managed sessions for those requirements.

Foundation limits: process creation is not yet a recoverable desktop-worker operation; ordinary conversation runtime state remains UI-owned, while Agents-workspace state and approvals are service-owned; no automatic reconciliation of uncertain native acceptance exists; source observation is partial and indexed only after hydration; recovery blocks uncertain sends rather than replaying them. Performance targets and native end-to-end acceptance remain unverified.

The installed Swift 6.4 swiftbuild backend intermittently omits the Testing macro plugin on incremental builds unless `--enable-swift-testing` is explicit. The explicit command passes; no toolchain installation or upgrade was performed.

## October 1 Agents Window implementation

- Added the **Agents workspace** with a board, searchable agent chats, an attention inbox, approval/question cards, persistent drafts, queued prompts with cancellation, dependency selection, and task archive/unarchive.
- Added provider/account/model selection, visible parent/child workers, side chats with complete available-context archives, result publication, scoped sibling messaging and paginated transcript reads. Child results queue to the parent after the native turn settles.
- Added `ShastraService`, `ShastraCLI`, private Unix-socket IPC, same-user peer checks, per-runtime tool grants, idempotent creation/send IDs, startup reconciliation, and service-owned vendor processes. New service sessions validate Codex MCP readiness and support native MCP approvals and Codex questions.
- Added dirty Git snapshots, idempotent owned worktree allocation, staged/unstaged/untracked transfer, source-drift checks, checkpoint forks, recoverable archive/restore, and committed-change integration. Archive refuses unpreserved ignored/private files. Cooperative writer limits do not lock out unrelated external editors.
- Event streams are consumed in order. Native turn completion remains distinct from acceptance criteria: tasks move to review; dependencies require both Done and completed status. Service interruption requires evidence that prior runtime ownership has ended, separately from uncertain delivery acceptance.
- `zsh Scripts/test.sh`: **18 Swift tests and 11 Claude bridge tests pass**. The script explicitly loads the installed Testing macro plugin to avoid the Swift 6.4 incremental-build issue.
- Live Codex and Cursor workers successfully discovered and called their scoped task-list MCP tool. Cursor’s one-time native approval was answered through the service. A worker completed while the UI was quit, with its reply persisted. These are managed runtime proofs, not desktop-thread control proofs.
- App version 0.3.0 packages the helper and CLI with the native UI. See [AgentsVerification.md](Docs/AgentsVerification.md).

Still absent: certified desktop sends/worker creation/return catch-up, managed-to-native endpoint handoff, automatic account failover, full plugin/account configuration reconciliation, scheduling, login launch registration, comprehensive performance/accessibility tests, and notarized distribution. The original full plan is not marked complete.

## October 1 quick chat and usage bar

- New chat opens an inline composer with remembered workspace selection, recent folders, folder browsing, provider/account selection, keyboard focus, and a persisted unsent draft. Creation is deferred until sending. The Agents workspace uses the same quick composer for background agents.
- A global bottom bar reads Codex account limits using the active account/profile environment, displays remaining percentages, and exposes reset dates and refresh status. Other provider quota adapters remain unavailable; no estimated percentages are shown.
- Automated checks: 20 Swift tests and 11 Claude bridge tests passed. A read-only live Codex usage probe returned a real weekly window and reset time.

- Cursor-style follow-up: project/worktree **+** buttons, workspace/branch and This Mac menus beneath all composers, isolated-worktree creation from the quick composer, and editable commit/push/PR/CI action requests. Existing runtime workspaces remain fixed; selecting a different workspace from an existing chat starts a new draft.
- Packaged UI verification confirmed workspace-row shortcuts, action drafting, footer menus, live quota details, and successful managed-agent creation in the selected disposable folder. See [Quick chat verification](Docs/QuickChatVerification.md).

- Sidebar simplification: each project now shows one chronological chat list across its main checkout and worktrees, with one project-level New Agent shortcut. Worktree headers and nested expansion controls are removed; chat-window workspace menus retain selection and details.

## October 1 visual system and coordinated layout

- Added shared semantic colors, typography treatment, spacing/geometry, primary/secondary buttons, status pills, focus surfaces, and empty states. Applied them to navigation, chat, Agents, account settings, quick search, and workspace tabs.
- Unified the three pane headers and titlebar safe area. Message and composer columns now share their width and margins. The workspace pane opens on demand and remembers the preference; file previews use the pane's available width.
- Added editable starter prompts, a direct linked-chat continuation action, legible agent states, compact recency labels, and more discoverable tool tabs.
- See [Design system](Docs/DesignSystem.md) for the framework and verification details.
- Validation: 20 Swift tests, 11 bridge tests, release build, and bundle signature passed. Three-pane alignment was visually verified. The Mac locked before final new-chat/Agents/dark-mode checks, which remain pending; unlock was requested through the UI.

### Compact top chrome follow-up

- Merged the titlebar and pane headers into one aligned 40-point row, reclaiming 36 points of vertical space. Native window controls retain a dedicated leading inset with the sidebar open or closed.
- Removed vertical centering and the oversized logo from new chat. Starter cards now fill the content width with consistent heights.
- Combined Agents status and actions into one toolbar; removed the repeated page title/subtitle and corrected the empty detail pane's minimum width.
- Release build and signature verification passed. Verified the running app in light/dark appearance, with sidebar expanded/collapsed, new chat, and Agents list/board. This also resolves the prior lock-blocked visual checks for those surfaces.

### Git-only workspace choices

- Sidebar project groups and recent workspace choices now include only Git repositories/worktrees. Existing non-Git histories remain stored.
- New chat prefers a valid recent Git checkout, normalizes subfolders to the checkout root, and validates the selection again before sending. Folder browsing and the agent creation dialog reject non-Git folders.
- Detached worktrees remain eligible; registered worktrees are available even without imported chats. Deleted worktrees retain historical project association but cannot be selected.
- All 22 Swift tests and 11 Claude bridge tests passed, including new real-Git fixtures for detached/unvisited worktrees, deleted checkouts, empty repositories, ordinary folders, and broken metadata.
- Final release build and signature verification passed. In the running app, verified the filtered sidebar/menu, detached-worktree selection, rejection of the non-Git `/tmp/shastra-ui-probe` folder, and selecting `/Users/arkokoley/code/Test` in the composer. No prompt was sent.

### Daily-use workflows and runtime library · 0.5.0

- Implemented all eight accepted usability directions: workspace discovery/defaults, consistent composer and background handoff, recovery, completion review, organization, model/context controls, message indexing/search, and opt-in notifications.
- Added skill/MCP copying with previews, name conflicts, format conversion, credential opt-in, private backups and drift-aware undo. User/project scope supported; saved-account profiles and runtime-specific/built-in tools remain outside the copier.
- Fixed saved Codex account configuration being overwritten on reconnect.
- All 29 Swift tests and 11 bridge tests pass; all release products build. App/service/CLI packaged as 0.5.0 (6).
- Relaunched the packaged app after the Mac unlocked. Verified workspace/model search, file chips, skill-copy preview, message search/navigation, completed-agent diff review, and organization/filter controls. No real prompts or runtime-copy operations were sent. Notification delivery and image paste remain unverified live. See [daily-use implementation and limits](Docs/UsabilityImplementation.md).

### Provider model discovery · 0.5.1

- Replaced aliases/global-file-only selection with runtime-backed Codex, Cursor, Grok and Claude discovery, scoped to the selected account/profile/workspace. Added searchable display names, provider metadata, favorites, refresh, cache/error states and a clearly marked custom-ID fallback.
- Preserved account/model on background continuation and child-agent creation; provider changes clear incompatible model IDs. Codex receives the model at thread start as well as turn start.
- Added read-only `ShastraCLI models` JSON output and a prioritized [product readiness backlog](Docs/ProductReadiness.md).
- All 35 Swift tests and 13 bridge tests pass; release products build. Real read-only probes returned Codex 4, Cursor 246, Grok 4 and Claude 5 catalog choices. A saved Codex account independently returned its catalog. No inference prompts were sent.
- Packaged UI verified: selected-account Codex metadata, Cursor model search, exact-ID selection into the composer, default restoration, and cache reuse. No inference sent.


### Same-thread continuation · 0.5.2

- Imported runtime chats accept follow-ups directly. Foreground reconnects and background service restarts resume the stored native thread ID instead of creating a context-based replacement.
- Background handoff adopts the same chat and runtime identity without sending a prompt. Existing managed identities route back to the existing task.
- Provider ID mismatches and resume errors fail explicitly; no automatic new-session fallback. Changing providers remains an explicitly labeled linked-session action.
- 40 Swift tests and 14 bridge tests pass. All release products build; a live Codex probe resumed the exact disposable thread ID with no inference sent.

Cursor desktop limitation: a live disposable desktop thread was rejected by ACP (`Invalid params`), while the existing Cursor CLI test thread resumed successfully with the same ID. Cursor support confirms [separate desktop and CLI session stores](https://forum.cursor.com/t/local-ide-agent-chats-and-the-agent-cli-still-use-separate-session-stores/165486/8). Desktop-origin chats now show Open Cursor / Copy follow-up and do not silently create CLI replacements. Automatic same-thread delivery into Cursor desktop remains unimplemented.

- Packaged and signed 0.5.2 (8), restarted the idle background helper, and verified the running app: existing runtime chat has a direct same-thread composer; Cursor desktop chat shows Open Cursor / Copy follow-up with no linked-session creation gate. Restored the previously selected Cursor desktop chat. No inference prompt sent.

### Message copying · 0.5.3

- Added visible Copy controls to every message in Agents workspace, plus consistent response/user-message controls in ordinary chats. Full response copying preserves source Markdown; existing selectable text and Copy code controls remain available.
- Release build and signature verification passed. In the packaged app, copied the disposable SHASTRA-QUEUED-ACK agent response, pasted it into an empty draft and verified the exact text, then cleared the draft and restored the original conversation. No prompt was sent.
