# Claude Review — PR #1052

**Reviewers:** Claude Opus 5.5, with codex (GPT-6.1), review and re-review
**PR:** Send notifications as parts and let operators change their wording per type and language (mdon)
**Reviewed:** 2026-11-20 / 21

Item 20 of the boss's fourth Projects list. Codex read the whole `lib/` diff with numbered questions, then the fixes. Every finding was checked against the code first, and each fix has a test.

## Findings

### BUG - HIGH — two editors on one copy could overwrite each other (fixed)
The version check ran before the write, outside any lock, and a reset checked no version. Now saves and resets check and write under the setting row's lock, plus an advisory lock on the key for a first save, which has no row yet. Versions are tokens, never reused after a reset or across nodes. Tests: a stale save and a stale reset are refused; a new save after a reset gets a new version.

### BUG - MEDIUM — the editor pinned inherited wording (fixed)
A type with no wording of its own showed the default, not what it inherited from "Every notification". Saving then wrote the default as the type's own. The editor now starts from what the type really uses, says when that's inherited, and saves only the parts that changed (a textarea's `\n` for `\r\n` counts as unchanged). Clearing the last own part resets. Tests in `notification_messages_test.exs`.

### BUG - MEDIUM — Telegram over 4,096, losing the link, or empty (fixed)
- A quote with no room left, a setting line longer than the message, or a link-in-text retry could exceed the limit or drop the link.
- A saved text could come out empty.
- A link that is only the start of a longer one in the text counted as present.

The tail is now always kept, the quote then the line are cut around it, an empty saved text falls back to the default layout, and links are matched exactly. Tests in `message_parts_test.exs`.

### BUG - LOW — locales, the default's hash, the button refusal, a throw (fixed)
- `pt_BR` and `pt-BR` are one language.
- The hash includes the translated labels the default puts in.
- Only a refused button (not a rate limit mentioning a URL or buttons) triggers the resend without it.
- A `visible` check that throws counts as "no".

### NOT CHANGED
- **An operator may put their own links in the wording.** That's the job, and the permission is granted deliberately. Links stay http(s)/mailto only, and the button and the setting line's link stay the renderer's.
- **A sub-type's base type ranks before language.** Documented in `Messages`.
- **A module's own `notification_text` containing private content** is the module's to avoid. Projects keeps the comment out of the line.

## Verification
`mix precommit`; 130 tests in the touched areas, 0 failures.
