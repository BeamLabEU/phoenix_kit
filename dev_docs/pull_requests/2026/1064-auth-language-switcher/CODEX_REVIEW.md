# Review of #1064 · Auth-page language switcher

The setting defaults to enabled for existing installations. The shared auth wrapper reads it when the caller leaves the attribute unset. The Authorization settings form uses the existing security settings permission and saves both checkbox states.

**IMPROVEMENT - MEDIUM.** Added coverage for an installation with Languages enabled and exactly one language. Turning on the auth switcher still leaves that form without a language menu. The PR already exercises multiple languages, the disabled module, explicit component overrides and a save through the admin LiveView.
