# Daily-use implementation · 0.5.0

Implemented: searchable and pinnable Git workspace picker, remembered project workspace/provider/account/model/execution defaults, background execution by default, shared composer context controls, progress and recovery, completion review, persistent pin/rename/archive/unread actions and activity filters, model search/custom IDs, file references and pasted screenshots, indexed message search with snippets and navigation, opt-in actionable notifications, and previewed skill/MCP copying.

## Runtime library

Open **Shastra → Skills & tools…**, select source and destination providers, optionally choose project settings, select an item and preview. Existing names require a new name; no silent overwrite. MCP changes preserve existing configuration and save a private backup. Undo refuses to overwrite edits made after copying. Skills include supporting files and executable permissions. Authentication files and nested symlinks are rejected. Preview hides potential credential values, and copying configurations containing credentials requires an explicit toggle.

Supported destinations: user and project skill/MCP locations for Codex, Claude, Cursor and Grok. Saved Shastra accounts have separate configurations; this screen does not target those account profiles. Built-in tools, installed plugins, OAuth grants, and runtime-specific MCP fields are not portable through this copier. Restart the destination runtime and use its normal trust/sign-in flow. No tool server is executed during copying.

## Continuity and notifications

Imported native chats retain their source identity. Continuing in the background creates a managed task using a complete available-context archive; it does not take over the native session. Uncertain deliveries are never automatically replayed. Failed connection setup restores the draft and file references. The completion card displays recorded tool output and does not infer that tests passed merely because the agent finished.

Background tasks continue after the app quits. Notifications are opt-in and generated while the Shastra app is running (including with its window closed); clicking opens the relevant task. Notifications while the app is fully quit are not implemented. Images are supplied as local image-file references; image understanding depends on the selected runtime.

History indexing includes unopened imported conversations. Search offers message snippets and highlights/jumps to matching user/assistant messages. Indexing can be paused and retried. Unavailable native sources are counted in the status.

## Verification · October 2, 2026

- All 29 Swift tests and 11 Claude bridge tests pass.
- New transfer fixtures cover JSON → TOML → JSON, preserving unrelated settings/null values, redacted credential preview and opt-in, conflicts, source/destination drift, backup/undo, bundled skill files and executable permissions, path traversal, symlinks, unsupported transport/settings and variable expansion.
- Added preference/model migration and context/snippet checks. Existing integration tests cover indexed search, durable background execution, delivery recovery, and Git-only workspace selection.
- Fixed saved Codex account setup so reconnecting preserves custom configuration rather than replacing it.
- Release build of app/service/CLI succeeded. Packaged binaries and bundled dependency licenses updated to 0.5.0 (6).
- After the Mac unlocked, relaunched the packaged 0.5.0 app and verified the new-chat layout; Git workspace search by branch; model search/custom ID affordance; attaching/removing a workspace file chip; the skill inventory and destination/file preview; indexed message snippets and navigation/highlight; existing completed-agent review opening the actual Changes pane; and the organization menu and filter controls. No prompts or real runtime-copy operations were sent. Test draft/file selection was cleared.
- macOS notification delivery and image-paste interaction were not exercised live. Notification permission remains unchanged. History indexing was progressing through the real catalog during verification; fixture search tests pass, but full-catalog completion was not awaited.
