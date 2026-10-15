# Project context, feedback, forks, and multitasking

The implementation order follows the data dependencies: project context → message annotations → message forks → multitasking → change review. These workflows use the existing managed service, native provider permissions, and durable delivery queue.

## Cursor reference

Cursor's [multitasking documentation](https://cursor.com/help/ai-features/multi-agent) describes `/multitask` as dispatching requests to asynchronous subagents instead of serially queuing them. Its [April 24 announcement](https://cursor.com/changelog/04-24-26) also describes delegating queued messages. The main chat remains the parent.

[Cursor subagents](https://cursor.com/docs/subagents) start with clean context and an assignment containing the necessary information. They return results to the parent. They share the parent's checkout by default, with optional worktree or cloud isolation. Shastra defaults independent editing workers to isolated worktrees so they can run within its existing workspace writer policy. A message fork is a separate operation with inherited history through a selected boundary.

## Using the app

- **Project context** above the chat edits instructions, reference file paths, and recorded decisions. The repository's Git common-directory identity shares this context across worktrees without mixing similarly named repositories. Each request reads the latest saved revision. Reference paths are pointers for agents to read as needed.
- **Annotate** below a user or assistant message opens an exact-text selection view. Select a passage and write feedback. **Annotations** lists quotations, comments, resolution state, and linked tasks. Selected feedback can fill the original composer or start isolated workers. **Remember for project** explicitly promotes feedback to a project decision.
- **Fork from here** chooses a provider, account, model, assignment, and workspace isolation. The fork starts a fresh native session, with cloned transcript entries through the selected message only. It does not reuse vendor thread or item identities. **Compare fork** shows the original continuation beside the fork. **Bring result back** fills an editable draft in the original chat.
- In managed chats, **Multitask** delegates queued user follow-ups and enables independent background requests. It leaves the initial objective and worker reports in the main chat. **Run alongside** starts one focused child; **Queue** preserves sequential work; **Steer current task** waits for cancellation acknowledgement before sending a replacement instruction. Child cards expose status and open the corresponding chat. Worker reports are deduplicated per native turn.
- **Changes** offers Unstaged, Staged, and, for new managed tasks, Task changes. The task comparison uses a task-start Git tree including existing dirty state, without modifying the user's index. Hunk comments retain the displayed revision and quotation. Feedback fills the originating composer. Stage/unstage and confirmed discard operate on one selected tracked text hunk after checking its revision. **Trace** shows the objective, linked annotations, changed files, and recorded execution evidence.

The review takes inspiration from [dev.fast](https://dev.fast/) and its [MIT-licensed Whiteboard review package](https://github.com/devdotfast/whiteboard/tree/main/packages/review). It is a native Git review implementation; Whiteboard's Node server and AST canvas are not embedded.

## Boundaries

Forks copy conversation history, while files begin from the workspace's current state. Worktree isolation requires a committed Git repository. Worker changes stay in their worktrees until explicitly integrated. Existing account and service concurrency limits still apply. Native approvals remain visible and require the user's decision.

A changed source message invalidates an annotation anchor; its saved quote remains readable. Concurrent edits fail visibly rather than overwriting newer context or comments. Task baselines rely on local Git objects; an unavailable or pruned baseline fails visibly. Review comments preserve their original quotation when the diff changes. Hunk mutations are unavailable for task comparisons, renames, untracked files, and binary-only changes. This release has no AST canvas or direct file editor.

## Verification

`zsh Scripts/test.sh` covers Unicode selection boundaries, persisted feedback and optimistic revisions, project isolation across worktrees, fresh fork identities and boundary handling, idempotent service requests, clean worker context, isolated multitasking, queued delegation, parent reports, steering, and selected-hunk actions. Git tests verify that baseline capture preserves staged state, separates preexisting changes, applies only one hunk, and rejects stale mutations. Provider transports use fixtures for these tests; this does not certify every real provider/account combination.
