# AcousticMaps design reference

Artwork and colours live in `ios/Blob.xcassets`. Drag that folder into the Xcode project navigator
(tick "Copy items if needed" off, since it is already in the repo) and the names below work in code.

## Images

| Name | Use |
|---|---|
| BlobNeutral | Home and listening |
| BlobThinking | Finding a route, rerouting |
| BlobPointRight / BlobPointLeft | A turn is coming |
| BlobScared | Far off route, or walking the wrong way |
| BlobHappy | Arrived |
| CompassOpen | Open compass with needle, for static screens |
| CompassClosed | Closed compass (yellow lid with needle), also the app icon |
| CompassLid, CompassBase, CompassCover, CompassNeedle | Separate layers, only for the open/close animation |

All six Blob images are the same size (157 x 116 pt) with the body in the same place, so swapping them
does not move Blob. Body bottom-centre is at (77, 102) pt in that frame.

The four compass layers and CompassOpen/CompassClosed are all 360 x 382 pt and stack exactly.
Dial centre is at (155, 267) pt. Draw order: Lid, Base, Cover, Needle.
CompassNeedle is a square (193 pt) drawn flat: rotate it, then squash vertically by 0.39 and centre it on the dial.

## Colours

| Name | Hex | Use |
|---|---|---|
| Ground | #FBF8FF | Screen background |
| Ink | #1A1423 | Text and all outlines |
| BlobLavender | #E2D3F8 | Blob, soft highlights |
| Action | #4B2A8C | Buttons, route line, labels |
| CompassGold | #E9B824 | Listening state, position dot |
| Dial | #C9EEF7 | Compass face |
| CardGround | #F1E9FC | Instruction card |
| AlertGround | #FDE4DF | Off-route card |
| SecondaryText | #4A4458 | Supporting text |

## Type and controls

- Font: system rounded, e.g. `.font(.system(size: 26, weight: .heavy, design: .rounded))`
- Instruction 26-28, search field 20, supporting text 17, label 15 uppercase
- Every card and control: 2.5 pt Ink outline, 22 pt corner radius
- Talk button: 84 pt circle during a trip. Smallest tap target 44 pt
- Microphone icon: SF Symbol `mic.fill`
- Give every control a VoiceOver label and let text scale with Dynamic Type

## States (server sends one of these names)

| State | Blob | Says (example) | Haptic |
|---|---|---|---|
| idle | BlobNeutral | "Where to?" | none |
| listening | BlobNeutral | none | light tick when the mic opens and closes |
| thinking | BlobThinking | "One moment." | slow soft pulse |
| navigating | BlobPointRight / BlobPointLeft | "Turn right onto Tower Road." | 1 tap left, 2 taps right |
| off_route | BlobScared | "You're heading away from the route." | one long buzz |
| arrived | BlobHappy | "You made it." | rising triple tap |

## Motion (starting values, tune by eye)

| Moment | Duration | Feel |
|---|---|---|
| Lid flips open | 0.6 s | Spring, slight overshoot. Scale the lid vertically from its hinge (58% across, 56% down) |
| Blob hop | 0.7 s | Crouch, stretch in the air (about 96 pt high), squash on landing |
| Blob dive back in | 0.4 s | Shrink to 25% and fade |
| Lid snaps shut | 0.3 s | Accelerating, then a small wobble |
| Needle | Sways +-7 deg at rest, spins while thinking, turns toward the next turn |
| Blob idle | Breathes: 2-4% scale, 3.2 s loop |

Skip motion when Reduce Motion is on. Build these last, after the core loop works.
