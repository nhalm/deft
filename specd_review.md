# Review

## web-ui

**Finding:** Roster component exists but is not used in template — CSS transitions missing
**Code:** `chat_live.html.heex:56-67` renders an inline `<div class="roster-panel">` inside an `<%= if %>` conditional. The element is removed from the DOM entirely when hidden, so no CSS transition occurs. Meanwhile, `DeftWeb.Components.Roster` at `lib/deft_web/components/roster.ex` implements the same roster with CSS transitions (`transform: translateX(100%); opacity: 0` for hidden state), but is never imported or called.
**Spec:** Section 2.6 says "Uses CSS transitions for show/hide."
**Options:** (a) Wire in the existing Roster component replacing the inline HTML, (b) Add CSS transitions to the inline HTML by keeping the element in DOM and toggling visibility classes, (c) Accept the current behavior as functionally equivalent (roster shows/hides correctly, just without animation)
**Recommendation:** Option (a) — the component was already created for this purpose and just needs to be imported and used.
