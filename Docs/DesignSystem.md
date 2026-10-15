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

The app shares the website's cream canvas (`#F6F4EE`), olive ink (`#242820`), terracotta accent (`#B74D2E`), and pale olive selection surfaces. Dark mode uses warm charcoal surfaces and a lighter terracotta accent. Light and dark palettes are semantic tokens rather than independent component colors. Warning and failure treatments include an icon and label as well as a color.

Use 8-point control corners, 14-point cards, and 20-point composers. The reading surface stays quiet; only the composer receives a restrained shadow and a stronger focus border. Typography uses the system font for controls and reading, a bold lowercase `shastra.` wordmark, and Georgia for the new-chat heading, echoing the website's serif display accent.

The brand mark is the actual **श** glyph on a terracotta rounded square, matching the website header. `Sources/ShastraApp/Resources/ShastraMark.svg` matches `website/favicon.svg`. Keep these assets synchronized when changing the logo. The app loads its mark from a Swift package resource bundle; packaging includes that bundle and generates the Dock icon from the same SVG using `Scripts/generate-app-icon.swift`.

The compact Shastra mark, selected-row indicator, keyboard hints, and account/status treatments recur across the app. Keep status and provider menus secondary to the send action. Avoid decorative motion; keyboard focus and native accessibility behavior remain available.

## Glass and materials

On macOS 26 and later, custom action buttons, workspace tool tabs, composer context pills, and new-chat starter controls use Apple's native `glassEffect` with interactive feedback. Adjacent header and browser controls are grouped with `GlassEffectContainer`. Large navigation surfaces use `NSVisualEffectView` sidebar material; toolbars, the composer, account panels, the command palette, runtime library, and agent navigation use regular translucent material so the glass control layer remains distinct from readable content. Conversation messages, code, and web content retain their reading surfaces.

macOS 15–25 use native material fallbacks. Reduce Transparency and Increase Contrast replace custom glass and material surfaces with semantic opaque fills. Light and dark appearance continue to follow the existing appearance setting. The Shastra terracotta accent and **श** mark remain consistent across appearances.

## Interaction

- New chat starts 24 points below the header with a compact heading and no vertical centering or oversized logo. Agents uses one compact status/action toolbar below the shell header.
- New chat offers three editable starting prompts: build, debug, and explore. Choosing one fills the composer and focuses the input; it never starts an agent automatically.
- Imported history has an explicit Continue action with an explanation of the linked session.
- Agent cards expose Working, Needs you, Completed, and failure states using words and symbols. The board provides counts and empty-column guidance; filters show a useful empty state.
- Account cards distinguish the default profile. Loading and errors offer an understandable state and recovery action where supported.
- Workspace tools use compact icon tabs, exposing the selected tab's title and a tooltip for every tab.

## Verification

For the website-brand revision, debug and release builds passed, the packaged bundle signature and logo resource were verified, and the generated icon was inspected. Calculated contrast ratios for principal token pairs are 13.64:1 (light body), 4.88:1 (light muted), 5.06:1 (light primary button), 15.41:1 (dark body), 8.07:1 (dark muted), and 8.03:1 (dark primary button). These are token checks, not a claim of a full accessibility audit. Running-app visual verification was blocked by the local Orca CLI failing to resolve its app path.

Reference framework: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/). The specific geometry, palette, and components above are Shastra's implementation choices.

Earlier layout revisions passed all 20 Swift tests and 11 Claude bridge tests, their release build, and bundle signature checks. Those revisions were visually inspected with unified 40-point headers, sidebar expanded/collapsed, full-width file navigation, compact tool tabs, top-aligned new chat in light/dark appearances, equal-height starter cards, and the compact Agents list/board toolbar. These historical checks do not verify the current branding revision. No model requests were sent during those layout checks.
