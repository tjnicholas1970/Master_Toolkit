# Changelog

## 4.1
- Every prompt is now attached to the toolkit window and stays on top, so OOBE can't hide it. Prompts can only be closed with their own buttons, reopen if something else closes them, and log how they were closed.
- OOBE Prep always asks for the Group Tag, filled in with the tag already on file. If the hash step fails, you can choose Retry, Skip or Stop.
- Running the hash step again on the same serial replaces that serial's Autopilot CSV row instead of adding a duplicate.

## 3.x – 4.0
- Restarts now resume through a SYSTEM startup task that puts the toolkit back on the OOBE screen or any user's desktop, no matter which account signs in.
- Verify Fully Patched now fixes what it finds: it installs pending updates, restarts, and checks again.
- Dell Command | Update integration: live progress, translated exit codes, and automatic recovery from service exit codes 3000–3005.
- Settings file, session state that survives restarts, ticket notes, and the before/after HTML health report.
- SCCM/Intune tab, CMTrace-style log viewer, Office 365 fix pack, network tests, New PC Setup, OOBE Prep.

## 2.7 (2026-07-30)
- Menu cleanup: every action has one home tab, Quick Checks grouped into sections, shorter sidebar.

## 2.6 (2026-07-30)
- Event Log Viewer: scrollable Critical/Error list, time-range filter, export to CSV.
- More Quick Checks, including activation, certificates, proxy/WPAD, startup apps and a support ZIP.
- Fast Nuke and Delete Profile now require typing YES.

## 2.5 (2026-07-30)
- Added the read-only Quick Checks tab, with a "Run All" button.

## 2.4 (2026-07-30)
- Single `.bat`: the USB can be removed after launch, the toolkit copies itself to a temporary folder, and it cleans up on close.
- Fixed a Windows PowerShell 5.1 parse crash caused by UTF-8 punctuation.

## 2.3 (2026-07-30)
- Reliability pass: reboot-resume fixes, Windows Update result codes checked before counting an install, Autopilot CSV always includes the Group Tag column.

## 2.1 – 2.2
- Combined clean-and-update flow, Fast Nuke SoftwareDistribution, Delivery Optimization cache flush; later split into separate Cleanup and Update buttons.

## 1.x – 2.0
- Separate Autopilot hash, update and repair scripts combined into a single toolkit.
