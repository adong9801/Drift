# Regression checks

- `zsh Tests/run.sh`: core logic, including memory-budget decisions.
- `zsh Tests/find.sh`: real WebKit searches in an isolated profile. Checks incremental search, keyboard focus, forward/backward wrapping, iframe text, case matching, cancelled searches, and view disposal. Saves `.build/find-bar.png`.
- `zsh Tests/launch.sh`: compiles a separate app and sends real Launch Services URL events from another process. Checks cold/warm launch, minimized and hidden windows, dismissing the address overlay, and multiple links. Uses a temporary profile and unregisters the test app afterward. Requires a logged-in macOS desktop session.
- `zsh Tests/resources.sh`: memory reclamation and protected-tab integration checks.
- `zsh Tests/smoke.sh`: broader browser and extension integration checks.

Find retains the ordinary text selection when dismissed, allowing the last match to be copied. The find indicator and pending search are cleared. Search result feedback uses WebKit's public match-found result; it does not claim a total match count.
