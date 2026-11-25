# Review of #1065 · Person cards and mention notifications

- **BUG - HIGH.** A mention could acquire a quote while its resource handler granted access and then deliver that quote after the handler disappeared. Delivery now withholds a stored quote when it cannot confirm visibility. Mentions created without a quote can still send their generic notification. The integration test checks both a permission change and removal of the handler.
- **BUG - MEDIUM.** The picker hid email addresses from viewers without the users permission, but its query still matched those addresses. The query now applies the same permission to email matching and display. It also excludes API-only accounts, whose person cards are unavailable.
- **BUG - MEDIUM.** Changing a resource link to a person mention with the same target left the old kind in the index and suppressed the ping. Sync now retains a row only while its kind still matches. The regression test edits a link and checks the recipient's inbox. Unchanged mentions retain their existing delivery claims.
- **BUG - MEDIUM.** The failed-card fallback accepted links that browsers could interpret as external. Its local-path check now rejects ambiguous leading separators and ASCII controls. The JavaScript tests cover three such links and the ordinary local profile link.

The catalogue merge preserves the added messages from both #1064 and #1065.
