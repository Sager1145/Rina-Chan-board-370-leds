# Adaptive SwiftUI LED Board Controller
## Apple UI guidance, verified Duo APIs, implementation policy, and validation plan

**Research date:** October 13, 2026  
**Audience:** Codex and the application developer  
**Reported environment:** Xcode 27; iOS 27.1 iPhone Duo simulator  
**STATUS:** RESEARCH COMPLETE — IMPLEMENTATION AND LOCAL VALIDATION NOT PERFORMED

This is an advisory implementation guide, not an audit of the application. No access to the developer’s repository, installed SDK, simulator, build output, or physical LED hardware was used. Code below is integration guidance and has not been compiled. Every test in the verification matrix remains **NOT RUN**.

**Evidence labels:** **Verified** means documented by an official Apple source inspected for this research. **App policy** means a recommendation for this controller, not an Apple requirement. **Local verification** means the exact SDK behavior or application result still needs checking. All source links are official Apple documentation, HIG, or Apple developer videos. The Duo-specific sessions are **Tech Talks**, not WWDC sessions; the WWDC references are labeled separately.

## 1. Executive decision

Apple’s Duo HIG emphasizes continuity of functionality and state between displays rather than a different product for each pose. [HIG Designing for iPhone Duo][S06]

Use native navigation and controls around a **geometry-driven, three-panel workspace**. Keep the preview, board controls, and selected editor as stable logical components. Interpret fold-related reserved regions as layout constraints; do not make the application’s structure depend on a device-name string or a guessed hinge angle.

Apple now publicly documents `ArrangementView`, reserved-region queries, and hinge interaction APIs. The correct conclusion is not that fold support lacks public APIs. The important distinction is their purpose: **arrangements and reserved regions serve layout; hinge callbacks serve interactions and effects**. [Adaptive layouts Tech Talk][S03] [Displays and scenes Tech Talk][S04]

For the requested exact three-panel regrouping, first evaluate the system arrangement where its behavior fits. Use a custom SwiftUI `Layout` when necessary to preserve the same three children while placing them into different regions. Do not force a two-content system arrangement to satisfy an undocumented three-content contract.

## 2. Confirm the SDK, not just the simulator runtime

**Verified:** Apple distinguishes apps linked against the iOS 27 SDK from those linked against iOS 27.1. The latter adopt full-display layouts and the new vertical-bar behavior on Duo. Apple names Xcode 27.1 for the Duo simulator. [Preparation guide][S01]

“Xcode 27” is therefore insufficiently specific. Record the exact Xcode build, selected developer directory, base SDK, simulator runtime, deployment target, and device identifier before evaluating results. A running iOS 27.1 simulator does not, by itself, establish which SDK compiled the app.

Commands for **Codex to run locally**; they were not run against the user’s environment:

```sh
xcode-select -p
xcodebuild -version
xcodebuild -showsdks
xcrun simctl list runtimes
xcrun simctl list devices available
```

The new SwiftUI arrangement and reserved-region declarations inspected here specify **iOS 27.1+**. An availability check protects execution on older operating systems; it does not make an older compiler/SDK recognize a missing declaration. Use a compatible SDK, isolate the new adapter behind availability, and retain a geometry-only fallback for older deployment targets. [ArrangementView documentation][S07] [Reserved-region query documentation][S08]

**Acceptance gate:** capture the local SDK evidence before changing layout code. Do not silently substitute a guessed API when compilation fails. Consult the actual SDK interface and release notes.

## 3. Required layout contract

Let **P** mean the LED preview, **C** mean the application’s board Control Center, and **T** mean the selected tab’s controls or editor. “Control Center” here is an app panel, not a claim that an iOS Control Center integration API is involved.

The following is the **user’s product contract plus explicit usability fallbacks**, not a hardware layout prescribed by Apple.

| Situation | Required composition | Geometry decision | Usability fallback |
|---|---|---|---|
| Folded / outer-display phone workflow | Familiar phone navigation; P, C, and T available in a compact workflow | Use the actual content container; do not identify this state by a fixed screen size | Stack or scroll content rather than reducing targets or clipping controls |
| Half-folded portrait / horizontal division | P in the upper usable region; C and T side by side in the lower usable region | Place boundaries relative to the reported active division, not `height / 2` | When lower panels cannot fit, stack them or provide an explicit accessible panel switch |
| Half-folded landscape / vertical division | Left region: P above C. Right region: T | Preserve the P+C relationship within one usable side | Each side can scroll independently; essential actions remain reachable |
| Fully expanded landscape / sufficient undivided width | Left column: P above C. Right column: T | Content-derived minimum widths and the available window size determine the split | Revert to the compact composition when minimum widths are not met |
| Fully expanded portrait | Not specified by the user | **Proposed policy:** choose the best fitting stacked or split composition | Preserve all functions without assuming a new “tablet mode” |
| Keyboard, extreme resizing, or accessibility text makes a preferred composition infeasible | Keep the active editing task and board controls usable | Treat this as a constrained variant of the current workspace | Do not preserve an exact half-height ratio at the expense of readable controls |

“Left/right” above describes the requested English, left-to-right experience. Decide and test content mirroring explicitly for right-to-left languages; hardware-constrained native bars are a separate matter.

**Policy priority:** unobstructed interaction → readable content → preserved task/state → preferred panel arrangement → decorative proportions. This prevents a visually accurate screenshot from becoming an unusable application.

## 4. Public API evidence ledger

| API or mechanism | Evidence and intended use | Important boundary |
|---|---|---|
| `GeometryReader`, `GeometryProxy.size`, `onGeometryChange` | Verified SwiftUI container geometry mechanisms. [GeometryProxy][S10] [onGeometryChange][S11] | Describe the view’s space, not a device identity or guaranteed posture |
| Horizontal and vertical size classes | Verified adaptive inputs. [Preparation guide][S01] | Regular width does not prove the device is an iPad |
| `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` | Full declaration inspected; iOS 27.1+. [Query documentation][S08] | Query the correct local coordinate space; consider arrays and active state |
| `ReservedRegion`, `.division`, `.occlusion` | Full documentation inspected; iOS 27.1+. [ReservedRegion][S09] | A divider and a camera occlusion require different handling |
| `ArrangementView`, `.arrangementViewStyle(.split)` and `.overlay` | Full overview inspected; iOS 27.1+. [ArrangementView][S07] | Two-content layout abstraction, not a replacement for navigation |
| `.split.axes(.horizontal)` | Verified in Apple’s adaptive-layout session. [Tech Talk][S03] | Restricting axes can make the system display only one content view; do not assume both always remain visible |
| `onHingeChange` | Name and interaction use verified in Apple’s displays-and-scenes session. [Tech Talk][S04] | Exact overload/context declarations still require local SDK inspection; unnecessary for the core layout policy |
| `UIHingeInteraction` | Official UIKit symbol and session discussion. [Documentation][S12] [Tech Talk][S04] | Do not turn continuous angle updates into global view invalidations |
| `UIView.reservedRegions(kind:)`, `UIArrangementViewController` | UIKit equivalents demonstrated by Apple. [Tech Talk][S03] [Controller documentation][S13] | Check exact overloads in the local SDK before writing UIKit bridge code |
| `Layout`, `AnyLayout`, `ViewThatFits` | Established SwiftUI tools. [WWDC22 layouts][S14] [AnyLayout][S15] [ViewThatFits][S16] | A fitting alternative does not by itself preserve arbitrary reparented view state |
| `FocusState`, safe-area APIs, UIKit keyboard layout guide | Established input/layout tools. [FocusState][S17] [safeAreaInset][S18] [UIKit keyboard guide][S19] | Do not mix screen-coordinate keyboard measurements with local pane coordinates |

This guide intentionally supplies no invented posture environment keys, device-model APIs, fold-angle thresholds, or simulator fold commands.

## 5. Geometry and reserved regions

### 5.1 Choose one coordinate contract

Use one measured workspace root, then express the layout plan and all reserved rectangles in that root’s coordinate space. Read geometry again when it changes. A region queried from a smaller child describes its intersection with that child, not necessarily the whole display.

Avoid global screen dimensions for pane layout. The window may resize or occupy only part of a display. Geometry and size classes are useful together; neither identifies hardware. Apple explicitly discourages device-orientation and idiom checks for choosing these layouts. [Preparation guide][S01]

**App policy:** define a small immutable `WorkspaceInputs` value containing the proposed content size, normalized usable bounds, active divisions, active occlusions, text-size category, and relevant editing constraints. Transform that value into a `WorkspacePlan`. Keep device marketing names out of both types.

### 5.2 Edge safe areas are not an interior fold model

Safe areas protect content from surrounding system interfaces and obstructions, but an interior reserved region is additional geometry. Native navigation should manage its own bars; custom workspace content must still respect interior exclusions. [HIG Layout][S20] [UIKit safe-area guide][S21]

Choose a single owner for edge insets. If a parent has already proposed safe content bounds, do not subtract those insets again and then apply equivalent padding. Only a deliberate decorative background should extend beyond the safe area. Avoid placing buttons, text fields, or important preview pixels under the camera or system bars.

For app-owned persistent actions, a safe-area inset can participate in content layout instead of painting an arbitrary overlay across a scroll view. Do not use it to manufacture a fixed “hinge inset.” [safeAreaInset documentation][S18]

### 5.3 Region details that materially affect correctness

**Verified:** `ReservedRegion.frame` already includes the region’s margins. Its `isActive` flag is available. Queries default to `.mirrors` for layout-direction behavior; `.fixed` is available for deliberate nonmirrored coordinate handling. [ReservedRegion documentation][S09] [Query documentation][S08]

Accordingly, do not add the reported margins a second time. When using standard SwiftUI `Layout` placement, retain the normal mirroring contract unless there is a documented reason to override it. A physical-coordinate bridge needs an explicit conversion; do not mirror both the region and the final placement manually.

**Documentation discrepancy:** Apple’s adaptive-layout Tech Talk describes the default query as active-only, whereas the inspected method and type documentation describe intersecting regions regardless of active state. The guide does not resolve that contradiction by guessing. Request inactive regions explicitly when needed, and filter `isActive` for active avoidance. Verify the default separately in the installed SDK. [Tech Talk][S03] [Query documentation][S08]

An absent division does not prove that the device is flat: the current window or measured view might not intersect it. Do not turn absence into a hardware-state assertion.

### 5.4 Normalize before allocating panels

**App-specific algorithm contract:** intersect each active region with the measured usable bounds; reject nonfinite geometry and empty intersections. Recognize a clean spanning horizontal or vertical division only when it actually separates that workspace. Allocate on either side of its occupied band. For multiple or partial regions, use a deliberate obstruction-aware fallback rather than selecting `.first` and pretending it is a full-screen hinge.

Occlusions are exclusions, not necessarily instructions to split the entire workspace. A small camera rectangle should not automatically halve every pane. Test that important controls avoid its area, and prefer native presentation containers for menus, alerts, and sheets.

Continuous lists should remain continuous instead of having individual rows displaced across a fold. Split the workspace’s major regions, then allow the list inside its assigned pane to scroll. [Adaptive layouts Tech Talk][S03]

## 6. Concrete SwiftUI integration

### 6.1 A small, explicit region adapter

The following uses documented names and an app-defined snapshot type. It does not infer a posture from a model name or angle. Keep it separate from the planner so older operating systems can supply an empty-region snapshot.

```swift
import SwiftUI

// App-defined value, not an Apple posture type.
struct WorkspaceRegionSnapshot: Equatable {
    var size: CGSize
    var divisions: [CGRect]
    var occlusions: [CGRect]
}

@available(iOS 27.1, *)
func readWorkspaceRegions(
    from proxy: GeometryProxy
) -> WorkspaceRegionSnapshot {
    let divisions = proxy.reservedRegions(
        kind: .division,
        options: .includeInactive
    )
    let occlusions = proxy.reservedRegions(
        kind: .occlusion,
        options: .includeInactive
    )

    return WorkspaceRegionSnapshot(
        size: proxy.size,
        divisions: divisions.filter(\.isActive).map(\.frame),
        occlusions: occlusions.filter(\.isActive).map(\.frame)
    )
}
```

The region arrays are local to `proxy`; their frames include margins. The planner must receive usable bounds in that same coordinate system. This snippet deliberately leaves edge-inset ownership to the calling container. [Query documentation][S08] [ReservedRegion documentation][S09]

### 6.2 Keep three stable siblings; change their placement

A custom `Layout` can measure and place an unchanged set of children. `AnyLayout` similarly helps switch layout algorithms without exchanging the child hierarchy. That identity preservation does not extend automatically to arbitrary conditional subtrees. [WWDC22 layouts][S14] [AnyLayout documentation][S15]

The following original scaffold consumes an already validated plan. It is not a complete fold solver.

```swift
import SwiftUI

// All rectangles are in the measured workspace's local coordinates.
struct WorkspacePlan: Equatable {
    var size: CGSize
    var preview: CGRect
    var boardControls: CGRect
    var tabEditor: CGRect

    var frames: [CGRect] {
        [preview, boardControls, tabEditor]
    }
}

struct WorkspacePlacement: Layout {
    var plan: WorkspacePlan

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        plan.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 3 else {
            assertionFailure("WorkspacePlacement requires P, C, and T")
            return
        }

        for (subview, frame) in zip(subviews, plan.frames) {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width,
                    height: frame.height
                )
            )
        }
    }
}
```

Integration shape, with **app-defined views and a computed plan**:

```swift
WorkspacePlacement(plan: plan) {
    BoardPreviewPanel(/* shared preview data */)
    BoardControlPanel(/* bindings and command actions */)
    CurrentTabPanel(/* selected editor and scene state */)
}
```

Do not attach `.id(layoutMode)` to this workspace. Do not create its transport in `body`. The planner is responsible for finite dimensions, minimum-size feasibility, occlusion avoidance, and fallback selection. A proposed rectangle does not automatically clip an overflowing child or make its internal controls fit; each panel must support its proposed size and scrolling behavior.

The layout’s proposal and measured-root contract must agree. Do not use this scaffold inside an unconstrained scroll axis and expect `plan.size` to acquire a meaningful viewport automatically. Local measurement and RTL tests are mandatory.

### 6.3 Planning rules Codex should implement

| Planner decision | Recommended rule |
|---|---|
| Active horizontal spanning division | Reserve upper usable area for P; divide lower usable area between C and T only when their measured minimum widths fit |
| Active vertical spanning division | Reserve leading region for P+C; put T in the other region; preserve the requested LTR arrangement and define RTL policy explicitly |
| No relevant active division and sufficient width | Use a wide P+C / T composition, with no synthetic hinge gap |
| Not enough width | Use compact composition or a documented panel-switching fallback |
| Text enlargement | Recompute the minimum content sizes; do not simply scale down the whole interface |
| Keyboard appearance | Keep the task’s logical composition stable where possible; adapt visible height and scrolling rather than declaring a new physical posture |
| Multiple or unusual reserved regions | Choose a tested safe fallback, record a diagnostic reason, and avoid inventing a posture |

Minimum pane sizes should come from representative content measurements and usability tests. Any initial numeric breakpoint is an **app tuning parameter**, not an Apple-specified Duo constant. Leave a small, tested tolerance around transitions only if profiling demonstrates layout oscillation; do not add arbitrary angle hysteresis.

### 6.4 Where the system arrangement is preferable

Use `ArrangementView` for a genuinely two-content split or overlay whose automatic adaptation matches the feature. Its styles can change whether and how the secondary content appears. Preserve an explicit way to reach required content when a compact arrangement cannot display both. [ArrangementView documentation][S07]

For the exact requested shell, the challenge is that portrait groups **C+T**, while landscape groups **P+C**. Merely nesting two arrangement views can change ownership or hide content in unexpected ways. The stable-three-sibling planner above is a deliberate app-specific alternative, not an assertion that Apple requires custom layouts.

Avoid placing an arrangement inside a `List` or `ScrollView`, or placing a `NavigationSplitView` inside an arrangement. Keep navigation outside the arrangement and scrollable content within its assigned panels. [Adaptive layouts Tech Talk][S03]

## 7. Navigation, tabs, and toolbars

**Verified:** Duo’s native bars can be vertical on the outer display and in inner-display landscape. Their hardware-related placement is not simply the mirrored counterpart of an ordinary bottom tab bar. Use the native navigation containers rather than drawing or rotating your own imitation. [Raise the bar Tech Talk][S05]

“Folded is a regular iPhone” should therefore mean the regular **workflow, features, and information hierarchy**, not a requirement that the operating system keep tabs along the bottom.

Tabs select top-level destinations; they are not Send, Clear, Connect, or Start commands. Keep tab labels meaningful and stable. Actions belong in content controls or toolbars. Avoid making tabs vanish just because the device disconnects. [HIG Tab bars][S22]

**Recommended app architecture:** keep one native `TabView` shell throughout posture changes. Each tab may own a `NavigationStack` and a workspace root made from the shared P/C/T component. Store tab selection and per-tab navigation state outside posture branches. The selected workspace places T on the right when wide; that does not require a second tab bar inside the right pane.

Do not move the same `TabView` from the window root into a nested pane as the fold changes. Do not create competing root toolbars in P, C, and T. Treat shared preview/control implementations as reusable components, but keep high-frequency rendering active only for the visible presentation.

`NavigationSplitView` is appropriate for a real sidebar/content/detail hierarchy, not merely because a screen is wide. Its collapse behavior is a navigation decision. Do not substitute it for P/C/T positioning unless that hierarchy actually matches the workflow. [NavigationSplitView documentation][S23]

Native toolbar metadata matters. Use meaningful `Label` content, appropriate action placements, and priorities for essential actions; do not depend on a text-only custom toolbar view fitting every bar axis. Test automatic overflow and compact representations. Independently created UIKit bar views should not be assumed to match the behavior of the native navigation/tab controllers. [Raise the bar Tech Talk][S05]

**App policy:** keep Stop/Blackout readily available during active output. Settings and infrequent diagnostics may use overflow. A native overflow menu is acceptable; hiding the only stop action there is not the desired controller behavior.

## 8. State preservation and lifecycle

SwiftUI view identity determines view lifetime and state continuity. A layout transition that replaces a subtree can reset local state even when the new view looks equivalent. Move task-critical state to a stable owner; animation alone does not transfer ownership. [WWDC21 Demystify SwiftUI][S24]

| State | Recommended owner | Expected behavior during folding |
|---|---|---|
| Selected tab and navigation path per tab | Scene-level presentation model | Same tab and destination remain selected |
| Text draft, selected face, editing parameters | Editor/document model | No reset, lost text, or extra save caused by geometry |
| Selected board IDs and board order | Session model; durable storage if part of user configuration | Selection and order remain unchanged |
| Live connection and command pipeline | Explicitly owned connection service/actor | No reconnect or duplicate stream merely because views move |
| Preview frame and animation clock | Preview renderer/session | No unnecessary restart or playback jump |
| Scroll anchor and selection | Stable pane state keyed by durable item IDs | Restore a meaningful location after resizing |
| Text input and accessibility focus | Stable logical focus state, with targeted restoration when necessary | Do not steal focus on every geometry update |
| Sheet, alert, pending operation | Presentation/session owner | Remain valid or dismiss for an explicit task reason |

Use Observation to keep state dependencies scoped to views that need them; do not expose one large frequently mutating object to the whole shell and read every property in every panel. [WWDC23 Observation][S25]

`SceneStorage` is for scene-associated restoration state. It is not a replacement for durable saved faces, artwork, or recovery of an important text draft. Store persistent user work through the app’s normal persistence layer. [SceneStorage documentation][S26]

**App policy:** distinguish desired settings, pending commands, and hardware-confirmed state. A successful local animation or slider change must not be presented as proof that the board accepted a command. Geometry updates must never implicitly issue Send, Clear, Reset, or reconnect operations.

For multiple scenes controlling one physical board, define command ownership or arbitration explicitly. Share a transport only intentionally; scene-local navigation should not become global navigation. Apple’s scene guidance reinforces that windows/displays can change independently. [Displays and scenes Tech Talk][S04]

## 9. Dynamic Type and accessibility

### 9.1 Typography and layout

Use semantic text styles and support the full Dynamic Type range. Let labels wrap; replace cramped horizontal arrangements with vertical ones or fewer columns as text grows. Avoid shrinking text or clamping the accessibility sizes to preserve a screenshot. [HIG Typography][S27]

**App policy:** the lower C/T pair in half-folded portrait is the highest-risk layout. At large accessibility sizes, stack it or present one clearly switchable panel at a time. Keep the preview informative but allow it to yield space to editing controls. No task should depend on reading tiny values in a permanently narrow inspector.

Scale meaningful control symbols alongside text. A geometric LED drawing need not become a larger grid merely because text size changes, but its caption, status, and associated controls must remain readable. Provide complete labels in the interface rather than relying on clipped titles with tooltips.

### 9.2 Targets: use the current numbers accurately

The current HIG Accessibility table lists **44 × 44 points as the default iOS/iPadOS control size and 28 × 28 points as the minimum**. It also emphasizes spacing. Do not describe 44 points as an exceptionless platform-wide minimum. [HIG Accessibility][S28]

For this controller, adopt **at least 44 × 44 points of actual interactive area** for primary and frequent controls as an app design target. Increase size for critical or frequently used actions when practical. The lower HIG number is not a reason to pack the Control Center with tiny adjacent targets. Expanded hit regions must not overlap neighboring controls.

Prefer real `Button`, `Toggle`, `Slider`, `Picker`, and `Stepper` controls rather than gestures attached to images. A visible small symbol can sit inside a larger labeled button; decorative drawing should not masquerade as a fully accessible control.

### 9.3 VoiceOver and alternative input

Provide meaningful labels, values, traits, and actions for custom elements. Group related information without collapsing distinct interactive children into one inaccessible element. Verify accessibility behavior rather than assuming an attractive visual hierarchy produces a useful spoken hierarchy. [WWDC23 accessible apps][S29]

**Controller-specific requirements:** announce board name and connection status together; describe brightness with a unit; give color swatches names or numeric alternatives; label playback, Send, and Clear unambiguously. A disconnected indicator needs text or a symbol, not only a red/green color difference.

A preview should expose an informative summary and useful actions, not hundreds of individually announced decorative LEDs. A pixel editor needs a separate accessible editing strategy, such as cell selection with position/color values and explicit adjustment actions. An accessibility representation can complement custom drawing. [Accessibility representation documentation][S30]

Test VoiceOver traversal after regrouping P/C/T. Restore focus only when its previous target no longer exists; repeatedly forcing focus during hinge movement is disruptive. Support keyboard navigation and gesture alternatives for important operations. Do not make drag, swipe, hover, or a precise canvas tap the only way to choose a board or perform a command.

## 10. Controls and feedback for the LED domain

Choose a control for the operation it expresses. Buttons perform actions and should have clear labels and suitable roles. Sliders are appropriate for adjustable ranges, while precise numeric adjustments can benefit from a stepper or editable value. [HIG Buttons][S31] [HIG Sliders][S32]

| Operation | Recommended presentation | App-specific behavior |
|---|---|---|
| Connect / reconnect | Labeled action with progress and resulting state | Differentiate searching, connecting, connected, and failed |
| Brightness | Slider plus readable value; precise adjustment where useful | Separate UI value from acknowledged hardware value when needed |
| Speed / frame rate | Labeled range and explicit unit | Decide whether updates are continuous or committed; do not change semantics by posture |
| Operating mode | Picker or a small segmented choice when it fits | Maintain labels at large text sizes; use a menu or list if cramped |
| Send artwork | Prominent action with pending/completed/error feedback | Show the actual destination board or board group |
| Start / stop live output | Stable, labeled stateful control | Keep stop reachable while running; do not imply stopping the preview stops the board |
| Clear / reset | Explicit action with a descriptive consequence | Confirm destructive resets; do not interrupt every reversible adjustment with an alert |
| Color selection | Standard picker plus accessible value information | Provide more than color-only status and consider precise numeric entry |

A slider’s transport policy is not an Apple-prescribed networking rule. For this app, coalesce or commit changes according to the protocol and user expectations, always delivering the final chosen value. Never queue unbounded obsolete brightness commands while someone drags.

Do not interpret a transport failure as a reason to remove the entire editing UI. Keep offline drafts usable, disable only actions that genuinely require a connection, and explain the condition near those actions.

## 11. Lists, forms, and scroll ownership

Use lists for collections and forms for structured settings. Organize rows into meaningful sections, provide clear selection and navigation behavior, and let content determine row height. [HIG Lists and tables][S33] [SwiftUI List][S34]

**App policy:** board discovery, saved faces, and recent items should have stable IDs. Do not use array indices, mutable display names, or newly generated UUIDs as identity. Keep selection stable during a discovery refresh and make duplicate board names distinguishable.

Use a single coherent primary interaction per row; avoid a row-level gesture that intercepts its embedded buttons. Keep destructive swipe actions discoverable by another route when they are important. Display useful empty, loading, unavailable, and error states without replacing the entire navigation structure.

Assign one scroll owner per main axis. In compact mode, a unified phone scroll is often appropriate; in wide mode, C and T may need independent scrolling. Avoid unconstrained `List` inside `ScrollView`, nested same-axis scrolling without a deliberate interaction design, or fixed heights that make large-text rows disappear. Preserve scroll anchors across those presentation changes where feasible.

For a large face gallery, use lazy population and cached thumbnails. Do not decode all animation frames inside each row’s `body`. Keep pending transport progress from invalidating every row unnecessarily.

## 12. Keyboard and editing behavior

SwiftUI incorporates keyboard avoidance through safe-area layout. UIKit’s keyboard layout guide is preferable to subtracting a screen-space keyboard height from a local pane. Resizing and multiple windows make those raw-height shortcuts especially fragile. [WWDC23 keyboard session][S35] [UIKit keyboard guide][S19]

**App policy:** keep keyboard-constrained height separate from the stable workspace geometry used to choose the main composition. A keyboard appearing must not be mistaken for rotating the device or entering a different fold state. Preserve the division topology and adapt the active editor’s visible region. Concretely, prioritize the active division axis, then choose wide versus compact from available width and minimum pane widths—not from the width/height ratio of the keyboard-shrunken editor. If a separate window-level measurement is used, convert it into the workspace coordinate contract instead of mixing coordinate spaces.

Let the focused field scroll into view. Keep submit/send semantics explicit: Return in a multiline text editor should not unexpectedly transmit artwork. A keyboard toolbar can provide a dismissal action without covering content with a custom bottom overlay.

Example modifier pattern for a containing view; `draft` and `editorFocused` are app state:

```swift
@State private var draft = ""
@FocusState private var editorFocused: Bool

var editor: some View {
    Form {
        Section("Text to display") {
            TextEditor(text: $draft)
                .focused($editorFocused)
                .frame(minHeight: 120) // App tuning value; not a fixed maximum.
        }
    }
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                editorFocused = false
            }
        }
    }
}
```

`FocusState` represents input focus; use a stable logical field identifier when more than one field is present. The example does not include a network send action and does not disable keyboard avoidance. [FocusState documentation][S17]

Validate multiline input, selection, paste, non-Latin input composition, hardware keyboards, and folding with an active draft. Do not dismiss the keyboard simply because the parent receives a geometry update.

## 13. Motion, materials, and contrast

Liquid Glass belongs primarily to the functional navigation/control layer; ordinary materials support content hierarchy. Do not turn every content card and the entire LED preview into overlapping glass surfaces. Prefer system components and use custom glass selectively. [HIG Materials][S36] [WWDC25 Meet Liquid Glass][S37]

**App policy:** keep the bright, moving LED content visually separate from control text. Use stable readable panel backgrounds, especially for status, numeric values, and critical actions. Test light/dark appearance and increased contrast with the most challenging animation, not just a black idle preview. Avoid making an active connection identifiable only by a glow color.

Read `accessibilityReduceMotion` and `accessibilityReduceTransparency` when implementing custom effects. The corresponding SwiftUI environment values are documented. [Reduce Motion value][S38] [Reduce Transparency value][S39]

Use restrained, meaningful layout transitions; avoid unnecessary travel, bounce, parallax, or a second animation on top of continuous resizing. Respect reduced-motion preferences with reduced or absent decorative motion. [HIG Motion][S40]

**Controller-specific distinction:** reducing interface motion is not the same as altering the artwork sent to the physical board. Provide an explicit pause/static-preview option and a clearly separate board Stop/Blackout action. Do not claim system video flashing-light mitigation automatically covers a custom Canvas or external LEDs. Make flashing-content behavior and preview controls understandable without silently rewriting the user’s output.

For a simple custom transition:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Apply only to the intended presentation transition, not every frame update.
// .animation(reduceMotion ? nil : .easeInOut, value: planKind)
```

`planKind` here is an app-defined discrete presentation choice. Do not animate the whole model every time a preview frame or hardware statistic changes.

## 14. Preview rendering and performance

**Preview geometry policy:** preserve the actual board or composed-board aspect ratio. Fit the complete artwork into its panel instead of stretching LED cells or cropping important edge pixels. Extra space can remain a neutral preview surface; it need not become stretched content. Give an enlarged or full-screen preview an explicit exit and preserve the editor/session on return. For a pixel-editing view, use the same transform for drawing and hit testing, and test the mapping after every resize. A display-only preview and an interactive pixel editor should not expose identical accessibility or gesture behavior.

`Canvas` provides immediate-mode drawing, and `TimelineView` schedules time-dependent updates. They are relevant building blocks for a dense LED preview, but neither makes the surrounding application automatically efficient or accessible. [Canvas documentation][S41] [TimelineView documentation][S42]

**Recommended architecture:** keep the animation clock and frame rendering inside the preview subsystem. Publish slower, meaningful connection and editor state separately. Avoid representing every decorative pixel as an independently animated SwiftUI control, and avoid making the whole navigation shell observe a frame counter.

Precompute reusable LED geometry, cache thumbnails, and move expensive decoding and transformations out of `body`. Keep UI mutations appropriately isolated. An `async` function is not proof that expensive CPU work runs off the main actor; inspect the execution context. Maintain bounded frame and command queues, and define which work can be dropped when obsolete.

Pause unnecessary preview scheduling when its presentation is not visible or the scene is inactive, without accidentally changing the physical board’s intended playback. Do not maintain multiple active preview render loops for inactive tabs. Treat display cadence, hardware transmit cadence, and reported board frame rate as separate concepts.

Use Instruments to identify long view updates, excessive invalidations, hangs, and hitches. Apple’s SwiftUI performance session demonstrates the SwiftUI instrument and Cause & Effect investigation alongside other performance tracks. [WWDC25 performance session][S43]

**Measurement plan:** profile idle, continuous preview, rapid slider updates, gallery scrolling, keyboard input, and repeated resizing separately, then together. Record frame timing, long updates, memory growth, command backlog, reconnect count, and active render-loop count. Choose product budgets and document them; this guide does not invent an Apple-mandated frame-rate threshold.

The simulator can reveal layout and logic problems. It cannot certify real-device graphics, power consumption, radio behavior, external-board latency, or touch comfort. Report those as separate hardware-validation items rather than inferring them from a smooth desktop simulator.

## 15. Simulator and automation workflow

Apple’s Duo preparation session demonstrates opening, closing, rotating, and folding the Duo simulator through Device Hub controls. Use that supported UI to exercise transitions and intermediate poses. [Prepare your app Tech Talk][S02]

Start with a reproducible fixture: a known selected board, an unsent text draft, a populated gallery, a pending command, and an active preview. Capture the initial state before the transition and compare the result afterward. Test transitions in both directions; startup screenshots alone are insufficient.

Apple also supplies a resizability skill that can be exported using `xcrun agent skills export`. Treat its output as a review aid, not a test pass or a substitute for native simulator inspection. [Preparation guide][S01]

For automation, use XCUITest to verify element existence, visibility, values, focus-dependent flows, and actual interactions. Accessibility audits can detect issues in the currently presented interface; they do not replace manual VoiceOver testing or visits to every state. [WWDC23 accessibility audits][S44] [Audit API][S45]

Example test body, to be integrated into the local test target:

```swift
func testCurrentWorkspaceAccessibility() throws {
    let app = XCUIApplication()
    app.launch()
    // Navigate to a deterministic fixture before auditing.
    try app.performAccessibilityAudit()
}
```

Capture screenshots and a compact diagnostic record containing: Xcode/build/SDK/runtime, scene/window size, safe-area handling, query coordinate space, all region frames and active states, selected plan, text size, keyboard state, layout direction, selected tab, and relevant session IDs. Exclude credentials and sensitive user text from logs.

For hit testing, do not accept `exists == true` as proof of usability. Check `isHittable` where appropriate, inspect frames, perform the action, and verify its semantic result. Conversely, a custom gesture canvas may need a purpose-built test strategy rather than assumptions about one accessibility element.

No documented command-line fold setter was verified in this research. Do not invent a `simctl` posture subcommand. Use Device Hub, locally verified automation support, and app-level geometry fixtures for different parts of the test plan.

## 16. Verification matrix

**All rows: NOT RUN.** This is the acceptance plan, not a record of completed tests. “Pass” means the stated evidence has been captured and checked, not merely that the application launched.

| ID | Scenario | Pass condition | Evidence to retain |
|---|---|---|---|
| V01 | Toolchain and runtime | Exact base SDK and runtime support the adopted declarations and behavior | Version/SDK/runtime output and build settings |
| V02 | Ordinary non-Duo phone | Phone workflow remains complete; no artificial fold gap | Screenshot plus main task run |
| V03 | Duo folded outer display | Compact content and native bars are usable; no forced bottom-bar assumptions | Screenshot, element frames, task run |
| V04 | Half-folded portrait | P above active division; C/T below; no important control intersects excluded geometry | Region dump, plan dump, screenshot |
| V05 | Half-folded landscape | P+C on requested left side; T on right; touch targets remain available | Same geometry evidence plus interaction run |
| V06 | Fully expanded landscape | P+C / T layout uses extra width without a fake hinge gap | Plan and screenshot |
| V07 | Fully expanded portrait | Proposed fallback is coherent and feature complete | Product-policy review and task run |
| V08 | Repeated fold/unfold both ways | Tab, draft, board, playback position, and paths survive | Before/after state snapshots and recording |
| V09 | Rotation while half folded | Layout responds to actual regions and bounds, not stale orientation | Transition recording and region updates |
| V10 | Resizing near fit threshold | No oscillation, negative frames, or unusable slivers | Continuous resize recording and planner tests |
| V11 | Active / inactive region queries | Default-query behavior established; explicit filtering has intended result | Local SDK details and comparison logs |
| V12 | Camera/occlusion becomes active | Relevant content and controls remain usable | Occlusion frames and screenshots |
| V13 | No region intersects measured view | Layout remains valid without asserting a hardware posture | Fixture and live-window evidence |
| V14 | Multiple / partial reserved regions | Planner uses a documented safe fallback | Pure-planner cases and layout captures |
| V15 | Insets and native bar changes | No doubled padding or controls underneath bars | Bounds/inset logs and hit tests |
| V16 | Right-to-left locale | Content policy is consistent; no double mirroring; hardware bars respected | RTL screenshots and interaction run |
| V17 | Long localized labels | Essential labels remain intelligible and actions reachable | Screenshots at relevant widths |
| V18 | Every Dynamic Type size, including largest accessibility size | No required information/action clipped; C/T fallback works | Size sweep and task completion evidence |
| V19 | VoiceOver across transitions | Logical traversal; labels/values correct; no repeated focus theft | Manual notes or recording |
| V20 | Full Keyboard Access / alternative input | All essential actions reachable without touch-only gestures | Keyboard interaction run |
| V21 | Software keyboard in every required layout | Focused text remains reachable; keyboard does not cause false posture change | Before/after plan and recording |
| V22 | Hardware keyboard and IME composition | Draft, selection, composition, and submission semantics survive resizing | Editing regression results |
| V23 | Sheet, alert, picker, or pending operation during fold | Presentation stays contextual and state is not lost | Transition recording and result |
| V24 | Stop/Blackout while active | Action reachable in compact/wide/keyboard/large-text variants | Actual command outcome or deterministic mock |
| V25 | Disconnection / retry / offline editing | Truthful status; draft retained; no duplicate reconnect loop | UI state and transport logs |
| V26 | Multi-board selection and changing discovery list | Stable identity, ordering, and intended command targets | Model snapshot and command destination log |
| V27 | Tab changes and navigation restoration | No unexpected resets or duplicated live render loops | State comparison and instrumentation |
| V28 | Light/dark, contrast, reduced transparency | Labels and control states remain legible over worst-case content | Appearance matrix screenshots |
| V29 | Reduce Motion and paused preview | Decorative motion reduced; physical output behavior is explicit | Setting-specific recordings |
| V30 | Gallery and long settings lists | Smooth scrolling, stable rows, no nested-scroll trapping | Interaction and profiling trace |
| V31 | Sustained preview plus slider updates and resizing | No unbounded memory/queue growth or repeated global updates | Instruments trace and queue counters |
| V32 | Background/foreground and scene replacement | Correct session ownership, saved draft, no duplicate timers | Lifecycle and transport logs |
| V33 | Automated accessibility audit | Audit run on each material state; failures reviewed, not blanket-suppressed | Test report and narrow documented exceptions |
| V34 | Physical device and physical board | Touch comfort, display behavior, power and radio/command latency evaluated independently | Hardware test report; pending until available |

### Pure planner assertions

Every computed frame must be finite and nonnegative, respect its coordinate contract, and satisfy the active composition’s minimum dimensions. Assert non-overlap between unrelated interactive panels. Assert no intersection with reserved exclusions where the panel contract requires avoidance. Assert that fallbacks preserve an explicit route to every function.

Do not confuse the preview’s transparent/background area with an important-control exclusion. Test at the right granularity: some backgrounds may legitimately extend behind reserved areas while text fields and action targets must not.

## 17. Implementation sequence

| Priority | Deliverable | Completion evidence |
|---|---|---|
| P0 | Establish SDK facts; remove screen/model/orientation layout assumptions; define P/C/T contract | Build evidence and reviewed input/planner boundary |
| P0 | Stable scene/session ownership and explicit transport lifecycle | Fold transitions do not reset drafts or reconnect |
| P0 | Native tabs/navigation; region-aware geometry adapter and planner | V02–V16 evidence, including query-default discrepancy |
| P1 | Keyboard, Dynamic Type, VoiceOver, target sizes, and fallback layouts | V17–V24 acceptance |
| P1 | Truthful command state and failure handling | Deterministic pending/ack/error and reconnect tests |
| P1 | List identity, scroll ownership, preview isolation, and performance investigation | Gallery and sustained-use traces |
| P2 | Material polish and restrained transitions | Appearance/motion matrix, without regressions |
| P2 | Physical hardware sign-off | Independent device and board measurements |

Do not call the feature complete because only the four ideal screenshots match. The acceptance unit is a **preserved task through changing geometry**, with reachable controls and truthful board state.

## 18. Known uncertainty and explicit nonclaims

**Exact installation:** the reported Xcode version was not inspected. SDK linkage and availability remain a local prerequisite.

**Reserved-region default:** the inspected Apple sources disagree about inactive-region inclusion. The adapter makes active filtering explicit; default behavior needs a versioned local test. This is an evidence conflict, not proof of an application defect.

**Hinge overloads and thresholds:** names and intended purpose are verified, but this guide does not claim an exact locally compiled callback signature, angle threshold, transition timing, or hardware calibration. The layout does not require such guesses.

**Arrangement fidelity:** the built-in two-content layout is verified; exact compliance with the requested three-panel regrouping is not guaranteed by its existence. Prototype and inspect it before choosing it over the custom planner.

**Accessibility fallback:** replacing the lower side-by-side pair with stacked or switchable content is this guide’s explicit usability recommendation. It relaxes the preferred visual arrangement when necessary; it does not remove functionality.

**Physical posture versus local geometry:** an app window may not represent the entire display. No-region and wide-window observations should not be reported as physical-device facts.

**Testing and performance:** no build, simulator run, accessibility audit, Instruments capture, or hardware test was executed for the user. Code examples are uncompiled. The verification matrix contains no passes.

## 19. Official source index

Sources were inspected during research on October 13, 2026. Some Apple documentation pages require JavaScript; their official linked Markdown representation was used where available. Source pages can change. Exact API availability in the local SDK remains authoritative for compilation.

### Duo-specific guidance and APIs

- [S01 — Apple: Three steps to make your app shine on iPhone Duo][S01]
- [S02 — Tech Talk: Prepare your app for iPhone Duo][S02]
- [S03 — Tech Talk: Strike a pose with adaptive layouts on iPhone Duo][S03]
- [S04 — Tech Talk: Leverage multiple displays and scenes on iPhone Duo][S04]
- [S05 — Tech Talk: Raise the bar with iPhone Duo][S05]
- [S06 — HIG: Designing for iPhone Duo][S06]
- [S07 — SwiftUI: ArrangementView][S07]
- [S08 — SwiftUI: reservedRegions(kind:options:layoutDirectionBehavior:)][S08]
- [S09 — SwiftUI: ReservedRegion][S09]
- [S10 — SwiftUI: GeometryProxy][S10]
- [S11 — SwiftUI: onGeometryChange(for:of:action:)][S11]
- [S12 — UIKit: UIHingeInteraction][S12]
- [S13 — UIKit: UIArrangementViewController][S13]

### Layout, state, navigation, and input

- [S14 — WWDC22: Compose custom layouts with SwiftUI][S14]
- [S15 — SwiftUI: AnyLayout][S15]
- [S16 — SwiftUI: ViewThatFits][S16]
- [S17 — SwiftUI: FocusState][S17]
- [S18 — SwiftUI: safeAreaInset(edge:alignment:spacing:content:)][S18]
- [S19 — UIKit: Adjusting your layout with keyboard layout guide][S19]
- [S20 — HIG: Layout][S20]
- [S21 — UIKit: safeAreaLayoutGuide][S21]
- [S22 — HIG: Tab bars][S22]
- [S23 — SwiftUI: NavigationSplitView][S23]
- [S24 — WWDC21: Demystify SwiftUI][S24]
- [S25 — WWDC23: Discover Observation in SwiftUI][S25]
- [S26 — SwiftUI: SceneStorage][S26]

### Accessibility, components, appearance, performance, and testing

- [S27 — HIG: Typography][S27]
- [S28 — HIG: Accessibility][S28]
- [S29 — WWDC23: Build accessible apps with SwiftUI and UIKit][S29]
- [S30 — SwiftUI: accessibilityRepresentation(representation:)][S30]
- [S31 — HIG: Buttons][S31]
- [S32 — HIG: Sliders][S32]
- [S33 — HIG: Lists and tables][S33]
- [S34 — SwiftUI: List][S34]
- [S35 — WWDC23: Keep up with the keyboard][S35]
- [S36 — HIG: Materials][S36]
- [S37 — WWDC25: Meet Liquid Glass][S37]
- [S38 — SwiftUI: accessibilityReduceMotion][S38]
- [S39 — SwiftUI: accessibilityReduceTransparency][S39]
- [S40 — HIG: Motion][S40]
- [S41 — SwiftUI: Canvas][S41]
- [S42 — SwiftUI: TimelineView][S42]
- [S43 — WWDC25: Optimize SwiftUI performance with Instruments][S43]
- [S44 — WWDC23: Perform accessibility audits for your app][S44]
- [S45 — XCUIAutomation: performAccessibilityAudit(for:_:)][S45]
- [S46 — WWDC26: What’s new in SwiftUI][S46]
- [S47 — WWDC25: Get to know the new design system][S47]

The WWDC26 SwiftUI update is useful additional context for the current toolchain and system controls, but it does not replace the later, Duo-specific API and layout guidance. [WWDC26 session][S46] The general design-system session provides complementary context for native controls and visual hierarchy. [WWDC25 design-system session][S47]

[S01]: https://developer.apple.com/iphone-duo/prepare/
[S02]: https://developer.apple.com/videos/play/tech-talks/111461/
[S03]: https://developer.apple.com/videos/play/tech-talks/111463/
[S04]: https://developer.apple.com/videos/play/tech-talks/111464/
[S05]: https://developer.apple.com/videos/play/tech-talks/111462/
[S06]: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
[S07]: https://developer.apple.com/documentation/swiftui/arrangementview
[S08]: https://developer.apple.com/documentation/swiftui/geometryproxy/reservedregions(kind:options:layoutdirectionbehavior:)
[S09]: https://developer.apple.com/documentation/swiftui/reservedregion
[S10]: https://developer.apple.com/documentation/swiftui/geometryproxy
[S11]: https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)
[S12]: https://developer.apple.com/documentation/uikit/uihingeinteraction
[S13]: https://developer.apple.com/documentation/uikit/uiarrangementviewcontroller
[S14]: https://developer.apple.com/videos/play/wwdc2022/10056/
[S15]: https://developer.apple.com/documentation/swiftui/anylayout
[S16]: https://developer.apple.com/documentation/swiftui/viewthatfits
[S17]: https://developer.apple.com/documentation/swiftui/focusstate
[S18]: https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)
[S19]: https://developer.apple.com/documentation/uikit/adjusting-your-layout-with-keyboard-layout-guide
[S20]: https://developer.apple.com/design/human-interface-guidelines/layout
[S21]: https://developer.apple.com/documentation/uikit/uiview/safearealayoutguide
[S22]: https://developer.apple.com/design/human-interface-guidelines/tab-bars
[S23]: https://developer.apple.com/documentation/swiftui/navigationsplitview
[S24]: https://developer.apple.com/videos/play/wwdc2021/10022/
[S25]: https://developer.apple.com/videos/play/wwdc2023/10149/
[S26]: https://developer.apple.com/documentation/swiftui/scenestorage
[S27]: https://developer.apple.com/design/human-interface-guidelines/typography
[S28]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[S29]: https://developer.apple.com/videos/play/wwdc2023/10036/
[S30]: https://developer.apple.com/documentation/swiftui/view/accessibilityrepresentation(representation:)
[S31]: https://developer.apple.com/design/human-interface-guidelines/buttons
[S32]: https://developer.apple.com/design/human-interface-guidelines/sliders
[S33]: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
[S34]: https://developer.apple.com/documentation/swiftui/list
[S35]: https://developer.apple.com/videos/play/wwdc2023/10281/
[S36]: https://developer.apple.com/design/human-interface-guidelines/materials
[S37]: https://developer.apple.com/videos/play/wwdc2025/219/
[S38]: https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
[S39]: https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency
[S40]: https://developer.apple.com/design/human-interface-guidelines/motion
[S41]: https://developer.apple.com/documentation/swiftui/canvas
[S42]: https://developer.apple.com/documentation/swiftui/timelineview
[S43]: https://developer.apple.com/videos/play/wwdc2025/306/
[S44]: https://developer.apple.com/videos/play/wwdc2023/10035/
[S45]: https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit(for:_:)
[S46]: https://developer.apple.com/videos/play/wwdc2026/269/
[S47]: https://developer.apple.com/videos/play/wwdc2025/356/
