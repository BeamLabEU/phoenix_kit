# PR #1051 — People picker

Reviewed the merge and its row-ID follow-up through `050844355`.

**BUG - MEDIUM.** When a search showed the same person under two teams, selecting the first row ticked only the second. The parent received the correct person, but the first row still announced itself as unselected. The picker now retains each streamed row by its DOM identity and refreshes every listed row for the changed selection. The LiveView regression test selects from one team, clears from the other, and checks both rows and the parent's keys after each click.

The new assertion failed on the merge follow-up. All 16 picker tests passed against PostgreSQL with the fix, and the project precommit gate passed.
