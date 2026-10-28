# Quire on the iPhone Duo

Design notes for Apple's foldable iPhone (canvas:
https://claude.ai/artifact/L8kjQ6MXNqsNdFPr6WpGPX). Quire does not detect the
device; everything below follows the size class and the window size.

## Closed (≈ 466 × 678 pt, compact width)

The iPhone design as it is: Today / Inbox / Journal pages under the words-only
tab bar, the reader and composer pushed over the list.

## Open (≈ 890 × 626 pt, regular × regular, landscape)

The iPad layout from `claude/ipad-layout`: the narrow leading sidebar (folds to
a strip with the sidebar button or ⌃⌘S, remembered) replaces the tab bar, and an
entry opens beside the list once there is room. Fold and unfold resize the same
window, so the selection, scroll position and an open draft carry across. The
system status area sits on the right edge; Quire adds no right-hand rail.

## What this branch does

- Shell chosen by size class, not `userInterfaceIdiom` (`AppRoot`, `PhoneRoot`).
- List + reader side by side at regular width; the sidebar in place of tabs.
- Camera: on iOS the recorder and photo capture are the system camera
  (`UIImagePickerController`), which rotates and fits itself; they are not yet
  reachable from the iPhone design. The hand-built `AVCaptureVideoPreviewLayer`
  is the Mac sheet's, and it now fits (`.resizeAspect`) rather than fills,
  follows an `AVCaptureDevice.RotationCoordinator`, and re-fits on every layout;
  recordings and photos take the coordinator's capture angle.

## Waiting on the iOS 27.1 SDK or a device

- The hand-built tab bar (`QuireComponents.swift`) will not turn vertical under
  the 27.1 SDK; at regular width the sidebar replaces it, so check only that the
  closed screen still shows it.
- Hinge: check the list/reader split does not put a line of text across it.
- When a camera is added to the iPhone composer, present it full screen and
  check that a recording survives fold/unfold.
