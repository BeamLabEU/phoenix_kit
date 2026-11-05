# PR #1020 — Let a linked Telegram chat propose writes, held for confirmation and bound to that chat

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; nothing to fix, one improvement open for a decision

A chat could only read. It can now propose writes the way a session does: each is held in a confirmation row, and the row's
`context` names the bot and the chat that made it. A chat reads, turns down and redeems only its own rows; the person's site
session may act on any of them.

## Checked and sound

- **A chat cannot reach a row that is not its own.** `from_origin?/2` compares the three keys, chat id as a string, and a
  row with no context or a nil one is `false`. `own_origin/2` runs before `redeemable/3` in `redeem_for_session/2`, so a
  refusal says nothing about the row's status, and before `may_write/2` in `get_for_user/3`.
- **The link is checked first, every time.** `redeem_as/6` and both `Confirm` paths go through `link_scope/3`, the one place
  that rule lives, so an unlinked chat is refused before any row is read.
- **The whole request path repeats at the press.** `redeem_as/6` passes the tool, scope, permission and
  `api_session_write_modules` checks again, and `claim_token/3` spends the row atomically.
- **A row that changed stays bound.** `reissue_for_user/8` keeps the old row's `context`, and a site session redeeming a
  chat's changed row leaves the new row the chat's.
- **`context` means nothing else on such a row.** Only `Approvals` reads a row's `context` back as a snapshot
  (`approvals.ex`), and only for approvals.
- **No side door through control fields.** `scope_ref/1` is nil for a `:user` actor, so an `idempotency_key` from a chat
  is ignored rather than replayed, and a `confirm_token` is refused as it is for a session.
- **A button press resolves to the chat.** `chat_for_update/1` takes a `callback_query` only when its sender is the private
  chat's own id, so a press in a group is `:error`, and the docs now say so.
- **No stale "reads only" claim is left** in `Linking`, `Telegram` or the Machine API guide.

## Findings

### IMPROVEMENT - MEDIUM — a chat confirms its own proposals, dangerous tools included (open, for a decision)

`Flow.gate/1` sends every write of a `:user` actor to `session_flow/1` before it looks at `dangerous?/1`, so `danger: :always`
tools are held and confirmed like any other. For a session that is fine: the person is signed in. From a chat, the proposal
and the press both come from the same Telegram account, so whoever holds that account can run any write the user's default
role allows, in the modules an admin ticked "Agent may act" for. That box was written with a site session in mind, and it
now covers chats too, with no switch of its own.

It is opt-in where it counts: nothing happens unless a module passes `allow: :all` for a chat. Not changed, because it is
a product decision. If wanted, the small version is refusing `redeem_as/6` from a chat for a tool whose `danger` applies,
so those wait for the person's site session.

### NITPICK — a held row outlives the link (left)

`drop_links/2` leaves a chat's `unused` rows in place until they expire. The chat cannot use them, since the link is checked
first. The person's site session could still confirm one, which takes a deliberate press on a preview. Left.

### NITPICK — a rejection from a chat is logged without `via` (left)

The PR names this as a known gap: `reject_for_user/3` takes no `via`.

### NITPICK — no CHANGELOG entry (left, for the release)

## Validation

The PR's 41 new tests ran in the full suite on the pulled tree, with no failure in this code. Telegram itself is stubbed:
none of this ran against a real bot.
