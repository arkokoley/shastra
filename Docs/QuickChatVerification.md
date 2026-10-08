# Quick chat and composer verification

Verified October 1, 2026 in the packaged Shastra 0.3.1 app.

- ⌘N opens a focused inline composer without a setup sheet.
- The project-row `+` opens `New Agent in Test` with `/Users/arkokoley/code/Test` selected, independent of the last-used folder.
- The workspace dropdown changes the draft workspace. The provider menu changes account-limit context; Cursor does not inherit the previously displayed Codex percentage.
- Workspace/branch and This Mac menus appear beneath the input. The execution menu offers background continuation and, for Git workspaces, an isolated worktree.
- Debug CI Failure fills an editable message. Commit/push/PR actions also use the ordinary draft/send flow, preserving provider permissions. No Git mutation is performed by clicking a chip.
- Starting through the quick composer created managed task `1E045CA6-8133-BF82-F0B3-BACC47A592C3` in `/tmp/shastra-ui-probe`, native session `01a0f914-2bc3-7c33-8e1d-b3d06608d941`.
- During the menu keyboard check, Return submitted the CI draft in that disposable workspace. The test was immediately cancelled. A follow-up text-only verification completed with `SHASTRA-QUICK-CHAT-ACK`; the complete task journal contains zero tool actions. The test task was then archived.
- The bottom bar displayed a live Codex weekly allowance; its popover displayed the account, reset date, and refresh time. The remaining percentage updated after activity. The separate `ShastraSelfTest --usage-limits` probe also succeeded without creating a model turn.
- Twenty Swift tests and eleven Claude bridge tests passed. The final SwiftUI changes compiled in the release build, and the packaged app passed `codesign --verify --deep --strict`.

## Boundaries

Quota reporting currently supports Codex only. Missing windows and unsupported providers remain unavailable rather than showing an estimated percentage. Workspace/branch menus select existing checkout directories or create a new isolated agent; they do not change the branch underneath a running conversation. This Mac is the supported execution host; cloud hosts are not advertised.

## Sidebar refinement

The sidebar now renders one chronological list per project across every checkout, with one project-level `+`. Verified the packaged app shows AuriumOutreach's combined 972-chat list directly under its project, without Main workspace or worktree subgroups. Opening a chat retains the branch/workspace menu beneath its composer. Release build and bundle signature verification passed.
