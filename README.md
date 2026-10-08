# Shastra

[Project website](https://arkokoley.github.io/shastra/) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)

Shastra is a native SwiftUI macOS workspace for conversations with coding agents. This is a working prototype of the linked product plan, with automatic local history discovery and direct agent sessions. The Agents workspace includes managed worker coordination and a background service; the desktop continuity plan remains in progress.

The current implementation roadmap is [Desktop continuity and coordination](BUILD_PLAN.md), with [desktop compatibility research and proof procedures](Docs/DesktopCompatibility.md). It prioritizes existing threads in the Codex, Cursor, and Claude Code **desktop apps**, round trips back to those same threads, and cross-app agent coordination. Those desktop guarantees are not implemented by the current CLI/SDK transports.

## Available now

- **Agents workspace**: background worker chats, a task board, searchable transcripts, an attention inbox, provider/account/model selection, queued follow-ups, dependencies, parent/child assignments, and side chats carrying the parent’s available context. Each worker exposes its files, terminal, browser, and Git diff panels. Drafts and selected agent persist.
- **Managed coordination**: per-runtime MCP tools for spawning workers, reading authorized task-family history, messaging, cancellation, publishing results, and receiving queued parent reports. The service defaults to four parallel agents, at most two turns per provider account, and one Shastra writer per shared workspace. Native approval policies remain in effect.
- **Workspaces**: isolated Git worktrees include staged, unstaged, and eligible untracked state; private untracked filenames are excluded. Checkpoints can start a new worker without replacing the original workspace. Archive/restore preserves dirty changes and refuses to remove ignored/private files that are not backed up. Committed work can be integrated through the service CLI after clean-tree checks.
- **Background execution**: `ShastraService` owns Agents-workspace runtimes independently of the UI. A private Unix socket and scoped MCP grants expose the durable queue. Restarted active work requires ownership reconciliation; uncertain dispatches cannot be replayed automatically. This helper starts with the app, not at system login.

- A Cursor Agents inspired macOS workspace with one chronological chat list per repository on the left, agent conversation in the center, and resizable app panes on the right. Files open in tabs beside a file explorer; text uses AppKit with line numbers and basic syntax coloring. The interface supports light, dark, and system appearance, compact tool activity, expandable long prompts, and a context composer. Native message rendering supports headings, lists, quotes, tables, selectable code blocks, and copying responses. Sidebar grouping reads Git common-directory metadata off the UI thread, including registered worktrees whose folders are missing. Chats from pruned Codex, Superset, and Claude worktrees stay in their project when it can be identified without ambiguity; independent repositories with the same name remain separate.
- A native file tree, text and image previews, PDFKit viewing, Finder actions, a WebKit browser for sites and local development servers, a read-only Git changes and diff view, and an interactive terminal in each conversation's working directory. The terminal embeds [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as an AppKit view and includes its license in the app bundle.
- Automatic read-only discovery at launch and every 60 seconds from Codex, Cursor editor, Cursor CLI, Claude Code, and Grok local stores when present. Conversations load on selection. A compatible local rollout reader handles Codex histories newer than the installed CLI. Cursor folder metadata keeps chats from different worktrees together under their project. Loading failures offer an inline retry without recurring alert dialogs.
- Direct conversations through Codex app-server, Cursor ACP (`cursor-agent`), and Grok ACP (`grok agent stdio`), using each vendor's installed CLI and login. Messages and tool activity stream into the app. Cancellation and supported approval requests are exposed in the UI.
- Claude Code transport through the pinned official Agent SDK, with streaming, tool events, native approval and question cards, cancellation, and session IDs. The SDK bundles Claude Code; Node.js 18+ is required. An authenticated Claude turn remains unverified on this Mac.
- **⌘K** / **⌘⇧P** opens a native Quick Open palette for chat titles, projects, worktrees, workspace filenames, and actions. Arrow keys and Return navigate results. The composer shows the working folder and branch.
- GRDB/SQLite persistence under `~/Library/Application Support/Shastra`, with WAL, foreign keys, event revisions, indexed message search, native endpoint lineage, saved drafts, and a durable prompt journal. Legacy JSON and account metadata are backed up and validated transactionally before import; failed migrations remain visible and never silently load an empty history.
- Imported chats begin **View only**. **Continue with** explicitly chooses a linked managed runtime within the same logical conversation and preserves every original endpoint. Available history is archived in full for context transfer; the former eight-message/6,000-character truncation is removed. Unresolved source workspaces require an explicit folder selection. Desktop same-thread sending remains gated.
- Prompt intent is persisted before dispatch. Lost acknowledgement and interrupted dispatch become **unknown**, block another send on the conversation, and are never automatically retried. Legacy conversation sends use the in-process journal; Agents-workspace sends use the background service. Native desktop reconciliation drivers remain pending.
- Native account management for Codex, Cursor, Claude, and Grok: browser sign-in, saving supported existing local sign-ins, importing saved profiles, renaming/removing accounts, provider defaults, and an account picker in each chat. Managed sessions use separate credential stores; selecting a missing account fails instead of falling back to another login.

## Build and run

Requires macOS 15 or newer, Apple Silicon, and Swift 6. Command Line Tools are sufficient for the package and local app bundle.

```sh
git clone https://github.com/arkokoley/shastra.git
cd shastra
(cd Bridge/Claude && npm ci --ignore-scripts --no-audit --no-fund)
swift build
zsh Scripts/test.sh
swift run ShastraSelfTest
zsh Scripts/package-app.sh
open dist/Shastra.app
```

Install the vendor CLI you want to use for new conversations: `codex`, Cursor `cursor-agent`, or `grok`. Claude Code is included through `@anthropic-ai/claude-agent-sdk@0.3.286`; install Node.js and npm to build/use its bridge. Packaging installs the locked SDK dependencies and includes their licenses. Use **Accounts** at the bottom of the sidebar (or **⌘,**) to sign in or save an existing local sign-in. Discovery of existing local history does not require starting an agent. Shastra uses the selected working directory as the agent process's current directory and does not silently grant tool permissions.

The self-test also supports `--accounts`, `--terminal`, `--workspace-identity`, `--workspace-catalog`, `--catalog`, `--grok`, `--live-codex`, and `--live-grok`. Account tests use synthetic credentials in an isolated fixture home and do not change vendor logins. Live tests create temporary vendor sessions and require the respective installed, logged-in CLI.

`swift run ShastraSelfTest --claude-probe` checks Claude credential isolation, the Swift/Node handshake, the real SDK's missing-login error, and workspace filename search without an authenticated model turn. `(cd Bridge/Claude && npm test)` exercises streaming, approvals, questions, cancellation, and recovery with injected SDK fixtures.

## Start a chat quickly

Press **⌘N** or **New chat** to type immediately. Choose a recent workspace from the folder selector beneath the composer, or **Choose folder…** for another directory. Shastra remembers the last folder and preserves the unsent new-chat draft. Select the provider/account beside the folder and send; no conversation or runtime is created until that first send. Existing chats retain their original workspace.

Click the **+** beside any project to open a new agent with that workspace already selected. The sidebar combines main-checkout and worktree chats in one project list. Worktree details and selection live in the chat window. Beneath every composer, the branch/workspace menu reveals the folder, offers existing worktrees, and can prepare a new isolated agent. **This Mac** exposes local/background execution options. **Commit & Push**, **Commit**, **Create Pull Request**, and **Debug CI Failure** fill the composer with an editable request; sending it runs through the normal agent flow.

From **Agents workspace**, **New agent** (⌘⇧N) and **New chat** use this same composer and launch a background agent in the chosen folder. Worker assignments and side chats retain their advanced setup options.

The bottom status bar follows the selected chat's provider/account. Codex displays real remaining usage windows; click it for reset dates, additional buckets, and manual refresh. Limits refresh every minute through the read-only app-server API without starting a model turn. Unsupported providers and accounts without reported windows show **Limits unavailable**. Failed refreshes retain the last successful reading with a warning and timestamp.

## Add and switch accounts

**Switch accounts without restarting Shastra or manually rebuilding your conversation context.** Choose a saved account from the chat composer and keep your project and conversation in view. Wait for the current turn to finish; switching starts a fresh vendor session with the chat's context.

1. Open **Accounts**, choose Codex, Cursor, Claude, or Grok, and enter an optional name such as Work or Personal.
2. Choose **Sign in** to finish the vendor's browser flow, **Save current sign-in** to keep the local login, or **Import → Import saved accounts** to read supported account-manager profiles. Individual authentication JSON files can also be imported.
3. Choose **Use by default** for new chats. In an existing chat, use the account menu beside the agent name in the composer. Switching starts a fresh vendor session with the chat's context; wait for a running turn to finish before switching.

The implementation uses the snapshot approach examined in [Loongphy/codex-auth](https://github.com/Loongphy/codex-auth), with compatible imports from that tool, [reloadlife/cursor-account-switcher](https://github.com/reloadlife/cursor-account-switcher), and [niuahua/grok-switch](https://github.com/niuahua/grok-switch). It reads their saved formats directly and does not install or execute their binaries.

Credentials are vendor-format files inside app-owned directories under `~/Library/Application Support/Shastra/Accounts`, with directory permissions 0700 and file permissions 0600. The account index contains display metadata only. Codex uses a separate `CODEX_HOME` and file credential store; Cursor uses a separate home plus `AGENT_CLI_CREDENTIAL_STORE=file`; Grok uses a separate `GROK_HOME`. Managed launches remove conflicting inherited credential environment variables. Vendor apps' current credential files are not overwritten. Browser sign-in uses the installed official CLI, so its version must support these storage options. Full OAuth verification with multiple real accounts remains to be performed; synthetic process isolation and sign-in lifecycle checks are automated.

Claude uses a separate `CLAUDE_CONFIG_DIR` and the vendor's own subscription sign-in (`auth login --claudeai`). The vendor CLI verifies browser sign-in and keeps its own Keychain entry or credential file; Shastra retains that profile directory. **Save current sign-in** supports usable `.credentials.json` snapshots. Keychain-only current logins require **Sign in** to add a separate profile. Removing a Shastra profile does not revoke the vendor login. Claude respects its configured user/project/local permissions; approval choices apply once.

## Current limits

- Claude transport and account UI are implemented, but authenticated streaming, tools, resume, and two simultaneous real Claude accounts still need live verification. OpenCode and Hermes adapters are pending.
- Cursor editor history may be incomplete for conversations whose messages are not stored locally. Cursor CLI history is reconstructed from its local database and may omit vendor-specific content.
- Sidebar search covers conversation titles, loaded messages, and persisted messages through FTS5. Quick Open searches titles/context metadata and up to 20,000 workspace entries by filename, skipping generated folders and links. It does not yet index all imported message bodies.
- The file tree previews UTF-8 text up to 2 MB and images up to 30 MB; other files open in their default macOS app. The Git view shows text diffs, including staged and unstaged tracked changes. File editing and inline code review are not yet implemented.
- Imported/reopened chats and account switches create linked continuations. Native resume of another app's active session is not implemented. Account-manager imports support usable local OAuth/auth files; Keychain-only placeholders require a new browser sign-in.
- The app handles Codex command/file approvals, ACP permission choices, and Claude SDK permissions/structured questions. Other blocking request types may require vendor-specific support.
- SQLite migration, event history, and delivery recovery foundations are implemented. Indexing all unvisited native transcripts, native desktop reconciliation, and performance gates remain pending. Legacy entries without reliable source IDs retain unknown provenance rather than being assigned invented origins.
- Managed workers, worktree creation, and background execution are implemented in the Agents workspace. Desktop worker creation, native cross-app return, automatic account failover, configuration sync, GitHub review, login-item registration, and notarization remain unimplemented. Ordinary imported/direct conversation panes retain their earlier UI-owned transport until explicitly moved to a managed workflow.

## Next implementation steps

1. Prove existing-thread control and return in each original desktop app; keep desktop and managed-runtime capabilities separate.
2. Extend the implemented identity, observation, and dispatch foundations into one certified desktop round trip.
3. Extend the managed workspace snapshots into native cross-app handoffs and return catch-up.
4. Certify the managed coordination tools for desktop workers and prove native sibling messaging and result delivery.
5. Finish account eligibility/failover, setup sharing, and Orca-inspired navigation and review workflows.
6. Harden service crash/sleep/update recovery, login registration, compatibility, performance, accessibility, and distribution before expanding providers and schedules.

See [BUILD_PLAN.md](BUILD_PLAN.md) for ordered work packets, module boundaries, state machines, and acceptance criteria.

Protocol references: [Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md), [Cursor ACP](https://cursor.com/docs/cli/acp), [Claude SDK user input](https://code.claude.com/docs/en/agent-sdk/user-input), [Grok CLI](https://docs.x.ai/build/cli/reference).

See [PLAN_STATUS.md](PLAN_STATUS.md) for the milestone audit against the supplied plan.

Background grouping skips Git metadata in macOS-protected Documents, Desktop and Downloads folders to avoid blocking on an access prompt. Their imported chats remain available under their folder; repositories elsewhere still group their worktrees together.

## Persistence and recovery

The authoritative database is `continuity.sqlite`. `MigrationBackup-v1` preserves the original `conversations.json` and account index; credential stores are not copied. Once migration commits, the old JSON is no longer read or written. Do not run an older build as a rollback against new activity: it cannot read SQLite. Export using `ConversationStore.export(to:)` for an explicit recovery or restore a matched app/data backup. Context archives live in the private `ContextArchives` directory and may contain private messages and tool output.

`zsh Scripts/test.sh` exercises migration validation/rollback, event identity, namespace isolation, FTS updates, delivery deduplication, uncertain acceptance, capability gates, and complete context archives. [DesktopCompatibility.md](Docs/DesktopCompatibility.md) separates live observation evidence from unverified production desktop control.

## Agents workflow

Open **Agents workspace → New agent**, select a provider and folder, and describe the objective and acceptance criteria. Isolation requires a Git repository with a commit. A shared folder supports non-Git work and is serialized against other Shastra agents using that folder. While a turn runs, **Queue** adds follow-ups; queued messages can be removed. **Actions → Assign a worker** creates a child, while **Open a side chat** copies available context without automatically sending its result back. Set dependencies to **Done** after reviewing results; dependents also wait for the native turn to finish.

The inbox collects approvals, questions, failures, and ownership reconciliation. A completed model turn moves to **In review**, not **Done**. A service restart never assumes an old runtime stopped; inspect it before reconciling. Unknown delivery outcomes require evidence separately from runtime ownership. Checkpoints and archive snapshots are private app data; preserve this directory alongside the SQLite database when backing up.

The packaged CLI is `dist/Shastra.app/Contents/MacOS/ShastraCLI`. `snapshot`, `agents.spawn`, `agents.send`, `agents.cancel`, `threads.read`, and workspace lifecycle methods accept `key=value` arguments. Pass `operation_id=<original ID>` to reconcile an uncertain spawn or send without creating a new operation. MCP mode requires a scoped service-issued runtime credential and never reads the admin token. These grants enforce tool-level task-family access; processes running as the same macOS user are not an OS security sandbox.

Live managed-runtime coordination was verified on October 1, 2026 with Codex and Cursor. See [Agents verification](Docs/AgentsVerification.md) for evidence and explicit remaining boundaries.

## License

Shastra is open source under the [MIT license](LICENSE). Third-party dependencies retain their own licenses. See [CONTRIBUTING.md](CONTRIBUTING.md) to get involved.
