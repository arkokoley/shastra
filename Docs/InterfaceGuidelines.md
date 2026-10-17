# Interface quality audit

This pass applies the [Interfaces Interface Cheat Sheet](https://interfaces.dev/cheat-sheet) to Shastra's native SwiftUI controls. The requested `interface.dev` address did not expose that resource; `interfaces.dev` is the design engineering publication with the relevant checklist.

## Changes

- File-tree rows are native buttons with keyboard activation and selected-state semantics instead of tap-only containers. Their full paths are available in help text.
- Custom selection controls have an explicit focus outline, arrow-key focus movement, a minimum 28-point target, and noninteractive selection decorations. Switches, checkboxes, and copy controls have at least 28-point height without overlapping neighboring actions. File rows retain their dense 27-point native desktop layout.
- Model refresh, model selection, review refresh, and model favorites have descriptive accessibility labels. Model search has a persistent visible label. Long model names/details, file paths, and changed-file names remain available through help text.
- Copy completion posts a low-priority accessibility announcement. It does not interrupt the user with an alert.
- Managed-chat sends explain service-busy, uncertain-delivery, and unavailable-steering states inline. Whitespace-only drafts cannot submit. Runtime and delivery safety guards remain intact.
- Review failures have a labelled error and explicit retry action. Empty review scopes explain where to look next.
- Hover settles in 100 ms. Tool details enter near their trigger with a six-point offset and leave with a quieter fade. Reduce Motion uses an immediate detail transition. Existing native menu timing is preserved.

## Existing practices preserved

Semantic light/dark palette, native system type, tabular timers, bounded chat reading width, native focus behavior, descriptive confirmation actions, exact revision checks before Git mutations, reduced-motion support, and reduced-transparency/high-contrast glass fallbacks already exist. This pass keeps those foundations.

## Scope

These are native equivalents, not CSS copied into the app. Web font formats, browser hover media queries, web routing, and page-load behavior do not apply. Disabling submit until delivery is safe remains intentional: an ambiguous native send must never be replayed merely to follow a generic form guideline. The audit is focused on the composer, custom interaction controls, model picker, review pane, and file tree; it is not a claim of complete app-wide accessibility certification.

## Reason desktop reference

Inspected the installed Reason app on 2026-10-16, including its new-session composer, context menu, environment menu, and Connectors page. No messages were sent and no connectors or environments were changed. These are observed interface patterns, not verified claims about execution behavior.

Recommended follow-ups, in order:

1. **Unified context picker.** Reason groups files, repositories, sessions, skills, people, and devices in its mention menu. Shastra can bring its existing file references, project context, chat forks, and runtime skills into one searchable picker. Show exactly what will be attached before sending.
2. **Explicit execution environment.** Reason puts Cloud and This device in a searchable environment menu with a folder chooser. Shastra can combine its existing workspace/branch and execution controls into a clearer local-folder or isolated-worktree selection, with the current path visible before a run.
3. **Readiness in the integration library.** Reason distinguishes connected essentials, existing connections, installable catalog entries, and unavailable integrations, with a short capability description per item. Apply that distinction to Shastra's accounts and runtime library so discovery does not imply readiness.
4. **Progressive disclosure in the composer.** Reason keeps context, environment, and model controls near a quiet prompt and teaches shortcuts with small hints. Shastra can move less-used composer actions into Add while keeping execution state and account switching visible.

These follow-ups are recommendations from the inspected UI; they are not implemented by this interface quality pass. Reason's Loops and Pull requests navigation entries were visible but their workflows were not evaluated.
