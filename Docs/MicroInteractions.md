# Native micro-interactions

Shastra adapts interaction ideas from the [React Bits Micro collection](https://reactbits.dev/c/micro) into its existing SwiftUI interface. `MicroInteractions.swift` is an original native implementation; React components, JavaScript, and the React Bits runtime are not bundled.

| Reference | Where it appears | Native behavior |
| --- | --- | --- |
| Status Mark | Agent cards, task headers, conversation status | An idle ring becomes an indeterminate arc, check, attention mark, or stopped/failed cross, driven by the existing runtime state. |
| Lattice Loader | A running turn's header | A small wave of cells accompanies elapsed time from the actual dispatched request. No synthetic completion percentage is shown. |
| Thought Line / Call Chip | Recorded tool activity | A compact chip shows the event count and recorded time span. Its chevron turns and its detail panel folds open. Historical tool output is not labelled as a successful check or a live tool run. |
| Rubber Segment | Agent list/board, follow-up mode, review scope | A spring selection thumb glides between equal-width choices. Tab/Space and arrow-key selection remain available. |
| Squish Switch | Multitasking | The thumb compresses while pressed and springs between on/off positions. The service remains the authority for the resulting mode. |
| Spring Check | Annotation selection, new-chat background choice | The checkbox fills while its tick draws. It exposes native checkbox semantics to accessibility. |
| Prompt Bar | Composer focus and attachment chips | The focus border/shadow settle smoothly; attachment chips enter and leave within the existing composer layout. |
| Folder Float | File-tree folders | A small paper layer lifts as the folder opens; the existing directory action and children remain intact. |
| Confirmation / press feedback | Copy controls, glass buttons, starter cards | Copy swaps to a check and confirmation label without changing width. Repeated copies restart the feedback timer. Buttons retain native activation and gain a restrained hover lift or press spring. |

Animations are short and local. Reduce Motion removes spatial movement, selection travel, tick drawing, symbol replacement, and continuous status animation. Active lattice/arc rendering pauses when the scene is inactive. A running elapsed clock updates once per second and does not imply progress. Disabled controls cannot activate. Native glass, high-contrast, reduced-transparency behavior, and existing task/approval rules remain in place.

Shastra does not add the collection's paper destruction, pointer-dodging, rating, OTP, audio-recording, or drag-to-send interactions to unrelated controls. Sending continues to use the ordinary button and keyboard shortcut; animation cannot submit a prompt, dismiss an approval, or discard a change.
