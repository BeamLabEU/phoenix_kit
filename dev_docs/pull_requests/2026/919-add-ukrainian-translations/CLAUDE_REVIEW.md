# Claude review — PR #919 (2026-10-08): Add Ukrainian (uk) translations

- **Author:** Tymofii Shapovalov (@timujinne) · **Branch:** `timujinne:add-uk-locale` → `main` · head `a9d04548`
- **Files:** 7 (+15,701 / −3): `priv/gettext/uk/LC_MESSAGES/{default,errors,phoenix_kit}.po` (new), `mix.exs`,
  `CHANGELOG.md`, `test/phoenix_kit_web/gettext_test.exs`, `test/phoenix_kit/email/catalog_test.exs`
- **Verdict:** **REQUEST CHANGES.** The catalogues are technically clean and the Ukrainian is good overall,
  but the branch no longer merges (version/CHANGELOG conflict with 2.58.0, one new msgid missing), one plural
  entry shows the wrong number, and the files are not what `mix gettext.merge` produces, so the next merge by
  anyone rewrites 3,432 lines. All three are mechanical fixes; the language findings below are mostly polish.

## Scope

New `uk` catalogues for the three core domains, `uk` added to the two locale-list tests, `@version` 2.57.1 →
2.57.2 with an `### i18n` CHANGELOG entry. No code change: `PhoenixKitWeb.Gettext` picks the locale up from
the directory, and `DialectMapper` / `RecipientLocale` already map `uk`/`uk-UA` to `uk`.

## Verified (not taken from the PR text)

Every check below was run against all entries, not a sample. The checker is a standalone parser
(`python3 -I`, `/tmp/prreviews/scripts/pocheck.py`), and it was first run against a deliberately broken
`.po` to confirm it catches each defect class.

- **Headers.** All three files: `Language: uk`, `Plural-Forms: nplurals=3; plural=(n%10==1 && n%100 != 11 ?
  0 : n%10>=2 && n%10<=4 && (n%100<10||n%100>=20) ? 1 : 2);`. The expression was parsed and evaluated for
  n = 0…10,000 and matches the CLDR Ukrainian rule (and Expo's built-in `uk`) everywhere.
- **Coverage against the PR base `.pot`.** `default` 3,425/3,425, `errors` 24/24, `phoenix_kit` 7/7. No extra
  msgids, no duplicates, no `#~` obsolete entries, no empty `msgstr`, no `fuzzy`, every plural entry has
  exactly `msgstr[0..2]`, and the 55 + 9 plural entries are all filled.
- **Placeholders and markup.** `%{…}` (as multisets), `{{…}}`, `%s`/`%d`, HTML tag names and attributes,
  entities, Markdown link targets, `**` markers, URLs, newline counts and leading/trailing whitespace all
  match their msgid, with one exception (finding 2). For plural forms each form was checked against
  `msgid_plural`, because the Ukrainian form 0 also serves 21, 31, 101…
- **Script hygiene.** No Russian-only letters (ы э ъ ё), no mixed Latin/Cyrillic words (homoglyphs), the
  apostrophe is always `'`, quotes are «…» (straight quotes appear only inside code such as
  `{:vix, "~> 0.42"}`), and `ви` is lower-case mid-sentence throughout.
- **Tests.** `MIX_ENV=test PGDATABASE=pkcore_test_domovych_uk PGPOOL=10 mix test
  test/phoenix_kit_web/gettext_test.exs test/phoenix_kit/email/catalog_test.exs` → 48 tests, 0 failures.
- **Runtime.** `Gettext.dngettext(PhoenixKitWeb.Gettext, …)` under `uk` returns the expected forms for 1/3/15.
  Finding 2 shows the 21/31 case.
- **Nothing outside the declared files**, and no code touched.

## Findings

### BUG - MEDIUM: the branch conflicts with `main`, the version goes backwards, and `Panorama` is untranslated

`gh pr view 919` reports `CONFLICTING`. `git merge-tree origin/main pr919` (in a scratch clone) shows conflicts
in **`mix.exs`** and **`CHANGELOG.md`**: `main` is now **2.58.0** (released after this branch was cut from
`680973489`), so resolving the conflict with the branch side sets `@version "2.57.2"`, a downgrade.
2.58.0 also added one msgid, `"Panorama"` (`media_browser.html.heex:1760`). After a rebase the `uk` catalogue
lacks it, so the PR's "every msgid translated" claim no longer holds (`ru` has «Панорама»).

**Fix:** rebase onto `main`, run `mix gettext.merge priv/gettext --locale uk --no-fuzzy` (see the
IMPROVEMENT below) and translate `Panorama` → «Панорама». For the version: AGENTS.md says to bump `@version`
and write the CHANGELOG under the bumped heading, which now means **2.58.1**. Recent contributor PRs
(#910, #912) instead left `mix.exs` alone (#912 wrote its entry under `## Unreleased`); follow whichever the
maintainer prefers.

### BUG - MEDIUM: "Try again in a minute." shows "за хвилину" for 21, 31, 41… minutes

`priv/gettext/uk/LC_MESSAGES/default.po:10622`. `msgstr[0]` has no `%{count}`. In Ukrainian, form 0 is
used for 1, 21, 31, 41…, not only for 1. The lockout (`WebsiteAccess.Gate.lockout_minutes/0`, default 15,
no upper bound) can exceed 20, and the password-gate page then tells a visitor "Спробуйте ще раз за
хвилину." for 21 minutes. Verified at runtime: n=21 and n=31 both return the one-minute text. The preposition
is also wrong. «за хвилину» means *within* a minute; a wait is «через …», which this catalogue itself uses at
`:11936`.

| msgid | current | proposed |
|---|---|---|
| Try again in a minute. / … %{count} minutes. | [0] Спробуйте ще раз за хвилину. [1] … за %{count} хвилини. [2] … за %{count} хвилин. | [0] Спробуйте ще раз через %{count} хвилину. [1] … через %{count} хвилини. [2] … через %{count} хвилин. |

### IMPROVEMENT - MEDIUM: the files are not the output of `mix gettext.merge`: every `#,` flag is gone

The PR says the catalogues were "created with `mix gettext.merge priv/gettext --locale uk --no-fuzzy`", but
`uk/default.po` has **0** `#,` lines where `default.pot` and every other locale have 3,425
(`phoenix_kit.po`: 0 vs 7). Example: `default.pot:31` has `#, elixir-autogen` above `msgid "Dashboard"`, and
`uk/default.po:22-26` has none. Re-running that exact merge on a copy reports "0 new, 0 removed, 3425
unchanged" and the result differs from the committed file **only** by +3,432 flag lines. So the files were
rewritten by some other tool after the merge. Runtime is unaffected, but the next contributor who runs
`gettext.extract --merge` for any reason gets a 3,432-line diff in `uk` that has nothing to do with their
change.

**Fix:** run `mix gettext.merge priv/gettext --locale uk --no-fuzzy` and commit the result. No translations
change (verified).

### IMPROVEMENT - MEDIUM: short month names are not Ukrainian abbreviations, and dates come out as «8 Жов»

`default.po:5211-5266`, used by `PhoenixKit.Utils.Date.short_month/1` → `short/1` / `short_with_year/1` via
`"%{day} %{month}"` (`:13396`, `:13400`). Runtime output under `uk`: **«8 Жов»**, **«21 Лис 2026»**. Cutting
every month to three letters gives forms nobody uses («Кві», «Тра», «Чер», «Сер», «Жов», «Лис» = "fox",
«Гру»). A capital letter after the day number is also wrong. The CLDR `uk` abbreviations are lower-case with a
period (Polish in this repo also uses lower case: `sty`, `wrz`).

| msgid | current | proposed |
|---|---|---|
| Jan / Feb / Mar / Apr / May / Jun | Січ / Лют / Бер / Кві / Тра / Чер | січ. / лют. / бер. / квіт. / трав. / черв. |
| Jul / Aug / Sep / Oct / Nov / Dec | Лип / Сер / Вер / Жов / Лис / Гру | лип. / серп. / вер. / жовт. / лист. / груд. |

(These become "8 жовт.", "21 лист. 2026". If a column header needs a capitalised form, that is a separate
msgid upstream; the date use is the common one.)

### IMPROVEMENT - MEDIUM: "Trash" is «Кошик», which contradicts the glossary the PR cites

`default.po:5104` Trash → «Кошик», `:4920` Empty Trash → «Очистити кошик», `:5108` Trash is empty. →
«Кошик порожній.», `:12673` Trashed → «У кошику», plus every "move to trash" string. `GLOSSARY-uk.md` says:
*trash — «Видалені», to avoid confusion with the shopper's «кошик»*. The PR description says the opposite
(«trash "кошик" in the admin»). On a shop host the admin now has «Кошики» (ecommerce carts) in the sidebar,
and Media shows «Кошик порожній.», the exact text ecommerce uses for an empty cart (`ecommerce
default.po:2224`). «Кошик» is the familiar OS term, so either choice is defensible, but the glossary and the
catalogue should agree. Either switch to «Видалені» («Перемістити до видалених», «Очистити видалені»,
«Немає видалених файлів»), or update the glossary and say so in the PR.

### NITPICK: language polish (core)

Grouped by surface; most visible first. Each row is `default.po:line`, msgid → current → proposed.

**Auth, account, notifications (end-user facing)**

| line | msgid | current | proposed |
|---|---|---|---|
| 10096, 10100 | Please enter a valid email address(.) | Введіть чинну адресу електронної пошти | Введіть правильну адресу електронної пошти («чинний» means "in force", as of a law) |
| 10610 | This link is no longer valid. | Це посилання більше не чинне. | Це посилання більше не дійсне. (the other link errors use «недійсне») |
| 10926 | Someone started following you. | Хтось почав стежити за вами. | Хтось підписався на вас. («стежити за» reads as surveillance; Followers is «Підписники») |
| 10914, 10922 | Someone commented on / liked your post. | … вашу публікацію / ваша публікація | … ваш допис (the Posts module is «Дописи» everywhere else) |
| 8190 | Allow "Keep me logged in" (persistent sessions) | Дозволити «Запам'ятати мене» … | Дозволити «Не виходити із системи» … (the checkbox it names is `:1090` «Не виходити із системи») |
| 10327 | You have %{count} new %{label} %{period}. | У вас %{count} нових: %{label} %{period}. | Нові %{label} %{period}: %{count}. (not `ngettext`, so «У вас 1 нових» is ungrammatical) |
| 5374 | No comments yet. Be the first to comment! | … Будьте першим! | … Залиште перший коментар! (gender-neutral) |
| 10994 | Your secure login link | Ваше безпечне посилання для входу | Ваше захищене посилання для входу (`:5747`, `:5818` use «захищене») |
| 14656 | [Review account security](…) | [Переглянути безпеку облікового запису] | [Перевірити безпеку облікового запису] |
| 8417, 6915, 8636, 8672 | Dismiss / Dismissed / No dismissed… / Notifications you dismiss… | Відхилити / Відхилено / Немає відхилених … | Приховати / Приховано / Немає прихованих … (a dismissed notification is not "rejected") |
| 7377 | Sign in as user | Увійти як користувач | Увійти від імені користувача (matches `:9004`) |

**Time and counters**

| line | msgid | current | proposed |
|---|---|---|---|
| 4431–4449 | %{count}s/m/h/d ago | %{count}с тому, %{count}хв тому, %{count}год тому, %{count}д тому | %{count} с тому, %{count} хв тому, %{count} год тому, %{count} дн. тому (number and unit need a space; «д» is not an abbreviation; `:8129-8137` already use «%{n} дн. тому») |
| 5149 (in 5202) | %{count} failed | Не вдалося: %{count} | %{count} — не вдалося (it is interpolated mid-sentence into «Частково успішно: 3 файли завантажено, Не вдалося: 2 через …») |
| 10582 | That is more than a year away. | Це більше ніж за рік. | Це більш ніж через рік. |
| 1961 | Expires | Спливає | Діє до |
| 5971 / 6055 / 6059 | %{count} activity / No activities match… / No activities recorded yet | %{count} подія / Немає активностей… / Активностей ще не записано | keep «подія/події»: Немає подій, що відповідають… / Подій ще не записано («активність» has no natural plural) |

**Admin wording**

| line | msgid | current | proposed |
|---|---|---|---|
| 6484 | Live Sessions | Активні сеанси | Сеанси наживо (`:83`/`:170` "Active sessions" is already «Активні сеанси»; two pages, one name) |
| 12694 | Viewer (library role) | Глядач | Читач |
| 12967 | Comfortable view | Зручний вигляд | Просторий вигляд (density setting, the opposite of «Компактний») |
| 7518 | Site Identity | Ідентичність сайту | Айдентика сайту (or «Основне про сайт») |
| 9234 | Access requested. | Доступ запрошено. | Запит на доступ надіслано. («запрошено» reads as "invited") |
| 8238 | Cannot delete send profile | Не вдалося видалити профіль надсилання | Неможливо видалити профіль надсилання ("cannot" is a refusal, not a failure) |
| 387 | (%{count} for disabled modules, preserved on save) | (… зберігаються під час збереження) | (%{count} для вимкнених модулів — не змінюються під час збереження) |
| 2437 | Label | Мітка | Підпис (a field's display label, not a tag) |
| 2883, 9737 | header is set to / … is set to false | заголовок встановлено в / встановлено в false | … має значення / … має значення false |
| 9865 | … so the feed can be verified … | … щоб стрічку можна було перевірити … | … щоб карту сайту можна було перевірити … |
| 9311, 9316 | Crawlers / Crawler settings | Сканери / Налаштування сканерів | consistent with the rest of the module («пошукові роботи»): Пошукові роботи / Налаштування для пошукових роботів |
| 3942 | e.g., Production Media, Backup Storage | напр., Production Media, Backup Storage | напр., Робочі медіа, Резервне сховище |
| 2012 / 8576 | Set Default / Make default | Зробити типовою / Зробити основним | one verb for one action, e.g. Встановити за замовчуванням |

**Consistency notes (no single right answer, pick one):**
- Provider fields are half translated in the same form: `:2093` Access Key ID, `:2147` App ID, `:2227` Client
  ID, `:2236` Client Secret, `:2208` Callback URL are left in English, but `:2664` Secret Access Key →
  «Секретний ключ доступу» and `:2120` uses «URL зворотного виклику». The billing PR translates Client ID /
  Client Secret / Callback URL. Leaving console terms in English is fine, but do it consistently across core
  and the modules.
- «від'єднати» (`:383`, `:592`) vs «відключити» (`:3036`, `:3289`) for "disconnect".
- «Адреса email» (`:5802`) vs billing «Адреса електронної пошти» for "Email Address".
- The daisyUI theme names (`:7201-7349`) stay in English while Light/Dark are translated. That is OK as proper
  names; `ru` translates them.

## Not flagged (checked)

The email templates (`:14644-14676`) read naturally, keep every `{{…}}`, button link and Markdown structure,
and use «Вітаємо, {{user_email}}!» consistently. The Ecto errors (`errors.po`) are idiomatic, and so are the
three plural families (files, folders, sessions, libraries, buckets, attempts). Form 0 also correctly carries
`%{count}` where the English singular has none (`:6287`, `:11737`, `:11744`).
