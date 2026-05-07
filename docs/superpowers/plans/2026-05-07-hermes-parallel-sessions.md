# Hermes Parallel Sessions Plan

## Goal

Make Hermes voice interactions support multiple independent tasks while preserving direct replies
to visible response windows.

## Behavior

- If the Hermes hotkey is pressed while a Hermes response window is visible, record a reply for
  that window's session.
- If no response window is visible, create a new Hermes session and send the dictation as a new
  task.
- Allow multiple response windows to exist at once. Each response window belongs to one Hermes
  session and can be copied, replied to, minimized, or closed independently.
- Persist Hermes sessions and messages across app restarts, capped to recent history.
- Rework the Hermes sidebar tab into a session list plus chat pane, with Settings kept as the
  second tab.

## Implementation Slices

1. Add `HermesChatSession`, `HermesSessionStore`, naming helpers, and hotkey-target routing.
2. Replace flat Hermes chat state in `DictationViewModel` with session-aware state while keeping
   a selected-session message projection for existing views/tests.
3. Send each Hermes API request with that session's unique `conversation` name so the Hermes
   server maintains separate response chains.
4. Convert the response window controller from a single panel to a panel registry keyed by
   session id.
5. Update `HermesAgentView` to show session rows, selected-session chat, reply/show/close actions,
   and the existing settings pane.
6. Update `datamodel.md` and `AGENTS.md`; verify with focused tests and a Debug build.
