# Shastra: what it needs to become a dependable daily workspace

Reviewed October 2, 2026. This is a prioritized product/engineering backlog, not a claim that every item below is implemented.

## Shipped in this pass: actual provider model discovery

The picker reads Codex `model/list` with pagination, Cursor `models`, Grok `models`, and Claude Code SDK `supportedModels()`. It uses the selected sign-in/profile and workspace; it does not substitute another account if lookup fails. Names, IDs, defaults, descriptions, and available capability metadata come from the runtime. Provider enumeration is not proof of quota or permission to execute every listed model.

The UI includes search, account-scoped favorites, a five-minute memory cache, explicit refresh, loading/error/cached-result states, and an explicitly custom-ID fallback. Saved IDs missing from the latest catalog remain visible and are never silently replaced. No model inference is used for discovery. Claude metadata lookup disables tools, configured MCP servers, hooks through the settings override, and session persistence; centrally managed policy remains authoritative.

The read-only CLI also supports `ShastraCLI models provider=codex|cursor|claude|grok [accountID=UUID] [workspace=/path] [profile=/path]`, returning model metadata as JSON without requiring the background service.

Child-agent dialogs inherit the parent account/model. Background continuations preserve the original choice. Changing the provider on a foreground continuation clears the old provider's model ID. Codex receives the model at both thread creation and turn start.

Sources: [Codex app-server model catalog](https://learn.chatgpt.com/docs/app-server#list-models-modellist), [Cursor model documentation](https://prod.cursor.com/help/models-and-usage/available-models), installed Cursor/Grok command help and Grok's bundled custom-model documentation, and the pinned Claude Agent SDK's `ModelInfo` / `Query.supportedModels` definitions. Runtime responses, rather than documentation examples, populate the picker.

## P0 — trust the app with real work

| Need | Why it matters | Concrete completion check |
| --- | --- | --- |
| Effective run configuration | A selected model is not always the actual model. Aliases, routing and project settings can change it. | Every turn records requested/resolved model, account, runtime version, execution host, workspace and supported effort. The UI distinguishes unknown metadata. |
| Model controls that are real | Reasoning, fast mode, context size and plan/ask/agent modes differ by runtime. | Render only advertised controls and test that each reaches the provider. Changing a model in an existing idle chat explicitly starts or updates the appropriate runtime; active runs remain stable. |
| Visible account health and quota | A catalog can load even when inference is blocked. | Authentication, quota exhaustion, reset time and provider outage are distinct states. Offer a deliberate account switch; never silently replay an uncertain send. |
| Reliable stop, resume and reconnect | Sleep, network loss and helper crashes are normal. | An in-flight command has a deadline and clear ownership; wake/restart tests preserve drafts, queued messages, approvals and unknown delivery state without duplicates. |
| Safe service upgrades | Replacing the bundle does not update a running helper. | Show client/helper protocol versions and defer helper replacement until owned runs are idle, with an explicit upgrade path. |
| Nonblocking history and navigation | Thousands of imported chats can dominate memory and UI updates. | Batch indexing and UI publication; incremental database writes; bounded transcript pages; performance fixtures at 10k chats; responsive typing during scans. |
| Review that closes the loop | An agent's “done” is not verification. | Show final diff, explicit recorded check outcomes, untracked files and unrelated pre-existing changes. Staging/commit/push present the exact changes and target first. |

## P1 — remove daily friction

| Need | Product behavior |
| --- | --- |
| Full keyboard workflow | New chat, workspace/model switch, next attention item, search, attachment removal, stop and review are reachable by keyboard. Popovers focus search immediately, support arrows/Enter/Escape, and expose accurate accessibility labels. |
| Draft and context management | Per-chat drafts survive restarts; image/file chips show type, size, existence and the exact scope being sent. Native image blocks are used where supported. Context budget, exclusions and missing attachments are visible before sending. |
| Scoped defaults | Project + provider + account defaults for model/mode/effort, with a visible “save as default” action. Overrides do not silently mutate unrelated projects or accounts. |
| Task queue and attention | One place for approvals, questions, failed work and reviews. Edit/reorder/cancel queued follow-ups; see dependencies, current activity and elapsed time without opening every chat. |
| Background notifications | Notifications while fully quit require service-owned delivery, launch/reopen routing, permission handling and deduplication. Add quiet hours and per-project controls. Existing notifications only run while the UI process is alive. |
| Workspace lifecycle | Show dirty state and branch collision before switching; offer existing/new worktree choices in chat; remember widths; explain missing/deleted worktrees; expose recoverable cleanup and disk use. |
| Search and import quality | Provider/account/project filters, snippets, stable deduplication, source badges and “open original” actions. Separate imported read-only history from managed execution and show indexing gaps. |
| Runtime library completion | Independent source/destination scopes, saved-account profiles, bulk transfer, dry-run differences, missing command/dependency checks, tool health, trust and OAuth reconnect. Plugins and built-in tools are separate from portable MCP definitions. |
| First-run setup | Detect installed runtimes and signed-in accounts, explain unsupported features, verify Git workspace and service health, then open a usable composer. Avoid an empty maze of settings. |

## P2 — expand once core workflows are dependable

- Checkpoints and branching conversations with inspectable context, rollback previews and explicit workspace effects.
- Remote hosts and cloud agents using the same execution contract and ownership rules as local runs.
- Scheduled work, wake/launch support, missed-run policy and notification routing.
- Usage/cost history with attribution by account/task/model; never invent prices for subscription or routed models.
- Team/project templates, reusable verified task recipes and shared default policies.
- Backup/export/import, migration recovery, redacted diagnostic bundles, and a local data-retention screen.
- UI refinement: compact/comfortable density, responsive three-pane sizing, reduced motion, contrast, VoiceOver and large-text checks.

## Release gates

A release is ready when real-provider metadata discovery works without inference; account switches cannot leak another account's catalog; saved defaults and custom models survive refresh; new/continued/child tasks receive the chosen model; cancellation and offline cases are tested; migrated data is intact; and the packaged app and helper advertise compatible versions. Price/capability fields stay absent when the runtime cannot substantiate them.

## Verification for 0.5.1

35 Swift tests and 13 Claude bridge tests pass. Fixtures cover exact IDs, aliases, hidden/default rows, ANSI/noise parsing, deduplication, model variants, optional capabilities, cache separation by account/workspace, preferences migration, missing-account rejection, and Claude metadata-query cleanup on success/failure. All release products build. Read-only probes through the new Swift reader returned 4 Codex, 246 Cursor, 4 Grok and 5 Claude entries on this machine, plus a separate saved-account Codex catalog. These are observed runtime catalogs, not a universal model inventory or proof of inference entitlement.

Packaged-app verification: Codex catalog/account/capability display, switching providers, Cursor search across 246 variants, selecting Composer 2.5, restoring provider default, and cache reuse were verified in the running 0.5.1 app. No prompt was sent. The user's Cursor/default-model selection was restored afterward.


## Same-thread continuation · 0.5.2

Follow-ups now resume the stored provider thread ID (`thread/resume` for Codex, `session/load` for ACP runtimes). Imported runtime chats are directly editable. Reconnecting a foreground session, restarting the background service, and restoring an archived workspace retain the native ID; the prior transcript is not sent again as context. An unavailable thread or an unexpected returned ID fails without creating a replacement session. Account changes cannot silently rebind an existing thread.

“Continue in background” adopts the existing conversation ID, native thread ID, workspace, account/profile, model and visible history. It does not send a prompt or open a new-chat composer. Opening an imported chat that already belongs to a background task routes to that task. Switching to a different provider is explicitly labeled as starting a linked session, since provider thread IDs cannot transfer across providers.

Verification: 40 Swift tests and 14 Claude bridge tests pass, including adoption idempotency, exact identity preservation, service-restart resume, no transcript replay, restore after workspace archive, account mismatch rejection, failed-resume behavior and Claude SDK resume without fork. A live Codex probe reopened an existing disposable test thread with the exact original ID and sent no prompt. Other providers use their resume APIs; runtime refusal is surfaced and never falls back to a new thread. Existing linked sessions from older versions are retained, not merged retroactively.

Cursor desktop limitation: a live disposable desktop thread was rejected by ACP (`Invalid params`), while the existing Cursor CLI test thread resumed successfully with the same ID. Cursor support confirms [separate desktop and CLI session stores](https://forum.cursor.com/t/local-ide-agent-chats-and-the-agent-cli-still-use-separate-session-stores/165486/8). Desktop-origin chats now show Open Cursor / Copy follow-up and do not silently create CLI replacements. Automatic same-thread delivery into Cursor desktop remains unimplemented.
