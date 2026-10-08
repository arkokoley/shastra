# Shastra interface system

Shastra uses native macOS interaction patterns with a small, shared visual system implemented in `Sources/ShastraApp/DesignSystem.swift`. The aim is a focused work surface with recognizable actions and useful feedback.

## Structure

- One Git project list in the sidebar. Non-Git folders are excluded without deleting history. Worktrees remain a chat-level decision.
- Workspace choices resolve to existing Git checkout roots, including detached worktrees and repositories without commits. Subfolders normalize to their checkout root; unavailable checkouts and broken Git metadata are excluded.
- A 252-point navigation rail, flexible conversation column, and optional workspace pane (390 points preferred, 350 minimum).
- All three headers share a 40-point row integrated into the native titlebar (previously 76 points including the separate titlebar). The shell and each native split-view child explicitly extend into the top safe area so their baselines stay aligned. The leftmost header reserves 72 extra points for native window controls, including when the sidebar is collapsed.
- Messages and the composer share a 740-point maximum content width and 24-point outer margins.
- The workspace pane starts closed for a fresh preference and remembers the user's choice. Files fill the pane until a selection opens a full-width preview; the explorer can be brought back with its existing toggle.

## Visual language

Warm pale surfaces and dark green-black ink keep content legible. Teal identifies primary actions, selected navigation, and active status. Light and dark palettes are semantic tokens rather than independent component colors. Warning and failure treatments include an icon and label as well as a color.

Use 8-point control corners, 14-point cards, and 20-point composers. The reading surface stays quiet; only the composer receives a restrained shadow and a stronger focus border. Typography uses the system font, with rounded semibold display text on the start screen and Agents heading.

The compact Shastra mark, selected-row indicator, keyboard hints, and account/status treatments recur across the app. Keep status and provider menus secondary to the send action. Avoid decorative motion; keyboard focus and native accessibility behavior remain available.

## Interaction

- New chat starts 24 points below the header with a compact heading and no vertical centering or oversized logo. Agents uses one compact status/action toolbar below the shell header.
- New chat offers three editable starting prompts: build, debug, and explore. Choosing one fills the composer and focuses the input; it never starts an agent automatically.
- Imported history has an explicit Continue action with an explanation of the linked session.
- Agent cards expose Working, Needs you, Completed, and failure states using words and symbols. The board provides counts and empty-column guidance; filters show a useful empty state.
- Account cards distinguish the default profile. Loading and errors offer an understandable state and recovery action where supported.
- Workspace tools use compact icon tabs, exposing the selected tab's title and a tooltip for every tab.

## Verification

Release builds passed. The running packaged app was visually checked with its workspace pane both closed and open: sidebar, chat, and tool headers share a baseline, and message/composer edges align. Calculated contrast ratios for principal token pairs are 12.62:1 (light body), 5.21:1 (light muted), 5.32:1 (light primary button), 14.86:1 (dark body), 8.02:1 (dark muted), and 9.74:1 (dark primary button). These are token checks, not a claim of a full accessibility audit.

Reference framework: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/). The specific geometry, palette, and components above are Shastra's implementation choices.

All 20 Swift tests and 11 Claude bridge tests passed for the design-system implementation. The subsequent spacing-only revision passed its release build and bundle signature check. The running final bundle was inspected with unified 40-point headers, sidebar expanded/collapsed, full-width file navigation, compact tool tabs, top-aligned new chat in light/dark appearances, equal-height starter cards, and the compact Agents list/board toolbar. No model requests were sent during these layout checks.
