# Customizing emails with template files

PhoenixKit's emails — account confirmation, password reset, magic link, the
new-login alert, the welcome email ([the full list](#phoenixkits-own-emails)),
and anything a module sends through
`PhoenixKit.Mailer.send_from_template/4` — ship with translated default copy.
A host changes that copy, or the HTML every email is wrapped in, by adding
**override files** to its own application. No database rows, no template
editor: the files deploy with the code. Only the branding — the project logo
and the `email_accent_color` setting — lives in the database, set in the admin
(see [Branding](#branding-logo-and-accent-colour)), so it can change without a
deploy. The admin also [previews every email](#previewing-emails).

## Where the files go

By default PhoenixKit looks in the host application's
`priv/phoenix_kit_templates/`. To search other directories instead, list them
(most specific first):

```elixir
# config/config.exs
config :phoenix_kit, template_paths: [Path.expand("../priv/email_overrides", __DIR__)]
```

An empty list means "no overrides": every email uses PhoenixKit's defaults.

## One directory per email

The email's **name is a directory**; the files inside are named for the part
they supply, optionally with a locale:

```
priv/phoenix_kit_templates/
└── magic_link/
    ├── subject.txt        <- every language
    ├── subject.de.txt     <- German readers
    ├── text.txt
    ├── markdown.md        <- optional: the body in Markdown
    ├── html.html          <- optional: the body in HTML
    └── layout.txt         <- optional: the name of a layout group
```

| part | file | |
|---|---|---|
| `subject` | `subject[.locale].txt` | subject line |
| `text` | `text[.locale].txt` | plain-text body |
| `markdown` | `markdown[.locale].md` | body in Markdown, optional |
| `html` | `html[.locale].html` | body in HTML, optional |
| `layout` | `layout.txt` | the email's [layout group](#layout-groups), optional — never per language |

The subject is one line: whitespace around it — the newline an editor leaves
at the end of `subject.txt` included — is not part of it, and a line break
inside it becomes a space.

Each part resolves on its own: for a reader in `de-AT`, `text.de-AT.txt`, then
`text.de.txt`, then `text.txt`, then PhoenixKit's translated default. A host
that overrides only `text.txt` keeps the translated subject in every language.

Placeholders are `{{variable}}`. In `html` and `markdown` a `{{variable}}`
is HTML-escaped; `{{{variable}}}` (three braces) inserts the value raw and is
only for a value that is already HTML.

### Which file makes which body

Each part comes from your file if there is one, else from PhoenixKit's (or
the module's) default. Each body then takes the first match:

| | HTML body | text body |
|---|---|---|
| 1 | your `html` | your `text` |
| 2 | your `markdown` | your `markdown`, as plain text |
| 3 | your `text`, escaped into paragraphs (addresses linked — see below) | default `text` |
| 4 | default `html` | default `markdown`, as plain text |
| 5 | default `markdown` | |
| 6 | default `text`, escaped into paragraphs | |

For the HTML body every file of yours comes before every default. So one
`markdown.md` is enough for both bodies, and it replaces the default copy in
both — add `text.txt` only when the plain-text version should say something
different. A `text.txt` on its own changes **both** bodies too: the HTML is
built from your text (paragraphs, addresses linked, no buttons), not from the
default Markdown that no longer says the same thing. To keep buttons — or a
module's richer HTML, such as an invoice's table of lines — override
`markdown.md` or `html.html` instead.

> Earlier releases put a `text.txt` after the defaults for the HTML body. It
> made no difference while PhoenixKit's own defaults were plain text; now
> that they are Markdown, a host that had overridden `text.txt` would
> otherwise have been sent PhoenixKit's wording in the HTML version.

The exception is an email sent [without the layout](#sending-one-email-without-the-layout)
(`layout: false`): there your `text.txt` builds no HTML, so the HTML version
still comes from the default `html` or `markdown`. Override `markdown.md` or
`html.html` for such an email to change both versions.

An empty or whitespace-only file counts as missing for the bodies. It still
hides the default of the same part — an empty `text.txt` does not bring back
a default `text` — but the next part in line is used: for PhoenixKit's own
emails, whose defaults are Markdown, an empty `text.txt` leaves the text
version to the default `markdown.md`.

Files are read once and cached; changing one takes a restart (a deploy).

## Writing the body in Markdown

`priv/phoenix_kit_templates/register/markdown.de.md`:

```markdown
Hallo {{user_email}},

bitte bestätigen Sie Ihr Konto:

[Konto bestätigen]({{confirmation_url}})

Wenn Sie sich nicht registriert haben, ignorieren Sie diese E-Mail einfach.
```

Headings, emphasis, lists, tables, strikethrough and links work as usual;
quotes and dashes are typeset (`"…"` → `“…”`, `--` → `–`).

**Buttons.** A top-level paragraph that is exactly one `[label](url)` link
becomes a button in the [accent colour](#branding-logo-and-accent-colour) — a coloured
table cell, which every email client draws, Outlook included. The text on it
is white on a dark accent and near-black on a light one. Any other link is a
plain link in the accent colour — including a link alone in a list item or a
quote. A bare address alone on a line stays a link — a bare `{{url}}` placeholder
does not (it is a word until it is filled), so write `[label]({{url}})`.

**Links.** Placeholders in a link target are filled in after the Markdown is
rendered, so `[Confirm]({{confirmation_url}})` opens the real address. Only
`http://`, `https://` and `mailto:` targets become links (images:
`http(s)` only); any other — `javascript:`, a relative path, a placeholder
nothing filled — leaves the label as plain text. This is checked on the
address *after* the placeholder is filled.

**Plain text.** Headings and paragraphs become lines, list items start with
`- ` (`1. ` when numbered), `[label](url)` becomes `label: url`, an image
becomes its alt text, and emphasis marks are dropped.

**The address written out.** `[{{url}}]({{url}})` is a link whose label is
the address itself; the plain-text version shows the address once. PhoenixKit's
own emails put one under each button — `If the button doesn't work, open this
link: [{{confirmation_url}}]({{confirmation_url}})` — for a reader whose
client does not draw the button.

**Optional paragraphs.** A paragraph of plain text whose placeholders all
come out empty is left out of both versions, so a value with nothing to say
(the new-login alert's `{{failed_attempts}}`) leaves no empty paragraph or
gap. Write such a placeholder on a line of its own.

**A block of HTML.** A paragraph that is exactly one `{{{variable}}}` is the
value alone, with no `<p>` around it — the way a caller places a table it
built between Markdown paragraphs. The plain-text version inserts the value
as is, so an email that does this needs a `text` of its own.

**HTML inside Markdown is not rendered** — it is dropped. A body that needs
markup of its own goes in `html.html`.

## PhoenixKit's own emails

Each one is a directory name under `priv/phoenix_kit_templates/`. Their
default copy is Markdown — the main action is a button, with the address
written out under it — translated into German, English, Spanish, Estonian,
French, Italian, Polish and Russian. Every email also sees `{{logo_url}}` and
`{{accent_color}}` (see [Branding](#branding-logo-and-accent-colour)).

| name | sent when | variables |
|---|---|---|
| `register` | after registration, to confirm the address | `user_email`, `confirmation_url` |
| `reset_password` | someone asks to reset a forgotten password | `user_email`, `reset_url` |
| `update_email` | a user changes their address (sent to the new one) | `user_email`, `update_url` |
| `magic_link` | signing in with a one-time link | `user_email`, `magic_link_url` |
| `magic_link_registration` | registering with a one-time link | `user_email`, `registration_url` |
| `organization_invitation` | an address is invited to an organization | `user_email`, `organization_name`, `registration_url` |
| `new_login_alert` | a sign-in from a device the account has not used | `user_email`, `login_time`, `ip_address`, `location`, `browser_os`, `failed_attempts`, `security_url` |
| `failed_login_alert` | repeated failed sign-ins | `user_email`, `attempt_count`, `window_hours`, `security_url` |
| `welcome` | once, after the address is confirmed — [off by default](#the-welcome-email) | `user_email`, `site_name`, `site_url` |
| `notification` | a notification the reader routes to email | `subject`, `text`, `url` |

`failed_attempts` is a sentence ending in a blank line, or empty when there
were none; `location` already says "(approximate)". `security_url` is the
account settings page. `notification` has no translated copy: its
`subject` (the notification's title, or the start of its text), `text` and
`url` (empty when the notification has no link) arrive already in the
reader's language; its default is `text`, `{{text}}` and then `{{url}}`.

### The welcome email

Off until you switch it on: **Settings → Emails Transactional → Branding →
Welcome email** (the `email_welcome_enabled` setting). It is then sent once
to each user, after they confirm their own address — by the link in the
confirmation email, by signing in with a magic link or with an OAuth
provider that verified the address while the account was unconfirmed, by
registering with a magic link, or by correcting an address they had not
confirmed yet ("Wrong email?"). An administrator confirming an account by
hand sends nothing.

The confirmation enqueues a background job (Oban, queue `notifications`) in
its own transaction; the job sends the email once the confirmation has
committed. So the email needs Oban running on some node, as notification
delivery already does — on a node without it the confirmation still
succeeds and the log says the welcome email could not be enqueued. Sending
never holds up the confirmation, and a confirmation that is rolled back
never sends one.

"Once" is recorded on the account (`welcome_email_sent_at` in its custom
fields) before the email goes out, so a confirmation repeated later never
sends a second one. A send that fails clears the mark and the job is retried
(up to three attempts).

The button leads to `{{site_url}}` — the site URL the footer shows. To say
more, or link elsewhere, override `welcome/markdown.md` like any other
email.

### Names PhoenixKit uses

The names in the table above belong to PhoenixKit — `welcome` and
`notification` among them. Give your own emails other names: a file
directory under one of these names rewrites PhoenixKit's email, and an
active database template of the emails module with one of these names
replaces it outright.

## The layout every email is wrapped in

Every email built from a file or a default is sent with an HTML body inside a
shared layout, made of three parts: the **layout** (the document), the
**header** and the **footer**. PhoenixKit's own are deliberately plain — the
logo (or, without one, the site's name) above the message, the name and a
link to the site below it, and — once the `email_accent_color` setting holds
a colour — a thin bar in that colour on top; table
markup with inline styles and no words of their own, so they need no
translation. The layout's `<html lang>` is the reader's locale (`pt_BR`
written as `pt-BR`).

- An email with only a `text` part gets its HTML body built from the text:
  every character escaped, a blank line starts a paragraph, a line break
  becomes `<br>`, and `http://`/`https://` addresses become links (no other
  scheme does, and neither does an address longer than 2 KB). The `text`
  body is sent unchanged next to it. An empty or whitespace-only part counts
  as missing, with or without the layout.
- An `html` part that is a fragment (`<p>…</p>`), or the HTML a `markdown`
  part renders to, is placed inside the layout.
- An `html` part that is a whole document — starting with `<!doctype` or
  `<html`, after any byte-order mark, whitespace, comments or `<?xml ?>`
  prolog — is sent as it is; it already has its own chrome.
- Emails still coming from database templates (the `phoenix_kit_emails`
  package) are never wrapped.

### Replacing the header, the footer, or the whole layout

Each is an override like any other, under a reserved name (names starting
with `_` hold shared parts, never an email of their own):

```
priv/phoenix_kit_templates/
├── _header/
│   └── html.html          <- the header of every email
├── _footer/
│   ├── html.html          <- the footer, every language
│   └── html.de.html       <- … and for German readers
└── _layout/
    └── html.html          <- the whole document
```

Each is resolved for the same reader and from the same directories as the
email it wraps, and only `html` is read. A host that wants its own header
writes `_header/html.html` and keeps PhoenixKit's layout and footer; an empty
or whitespace-only header or footer file counts as missing.

A header:

```html
<!-- priv/phoenix_kit_templates/_header/html.html -->
<a href="{{site_url}}"><img src="{{logo_url}}" alt="{{site_name}}" height="32"></a>
<span style="color:{{accent_color}};">Customer service</span>
```

Placeholders have no conditions, so a header written like this shows a
broken image while no logo is set — set the logo first, or keep PhoenixKit's
header, which falls back to the site's name.

A layout with no `content` placeholder — an empty file, or a typo such as
`{{{contnet}}}` — would drop the body of every email, the password reset
included. PhoenixKit refuses it: it uses the next layout in line (a group's
falls back to `_layout`, `_layout` to PhoenixKit's own) until the file is
fixed, and logs a warning the first time (once per layout, directory list and
language until the next restart). A header or footer needs no placeholder.

Variables available to the layout, the header and the footer:

| placeholder | value |
|---|---|
| `{{subject}}` | the email's subject, e.g. for `<title>` |
| `{{site_name}}` | the project title (the `project_title` setting, else `config :phoenix_kit, project_title:`) |
| `{{site_url}}` | the site URL used in email links (the `site_url` setting, else the endpoint's URL) — as configured; PhoenixKit's own footer links it only when it is `http(s)://` |
| `{{logo_url}}` | the project logo — see [Branding](#branding-logo-and-accent-colour); empty without one |
| `{{accent_color}}` | the accent colour, `#rrggbb` |

and to the layout only:

| placeholder | value |
|---|---|
| `{{{content}}}` | the email's HTML body |
| `{{{header}}}` | the rendered header |
| `{{{footer}}}` | the rendered footer |

Write `{{{content}}}`, `{{{header}}}` and `{{{footer}}}` with **three
braces**. They are already HTML, escaped when they were built; with two
braces they would be escaped a second time and the reader would see the tags
as text. Use two braces for everything else, so a subject or a site name
containing `<` or `&` cannot break the markup. A layout that places no
header or footer simply has none.

The layout, header and footer see only the variables above — not the
email's own (`{{user_email}}`, `{{confirmation_url}}`): they are shared by
every email, so a placeholder only some emails bind would stay visible in
the others.

A minimal layout:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>{{subject}}</title></head>
<body style="margin:0;padding:24px;font-family:Arial,sans-serif;">
  {{{header}}}
  {{{content}}}
  <div style="font-size:12px;color:#666;">{{{footer}}}</div>
</body>
</html>
```

Email clients ignore most of what a browser supports: keep styles inline, lay
out with tables, and do not rely on external stylesheets or web fonts.

### Layout groups

Some emails — invoices, say — want chrome of their own. A **group** is a name
(`[a-z0-9-]+`, e.g. `billing`) with its own layout, header and footer:

```
priv/phoenix_kit_templates/
├── _layout-billing/html.html     <- the billing group's document
├── _header-billing/html.html     <- the billing group's header
├── _footer-billing/html.html     <- the billing group's footer
└── invoice_paid/
    └── layout.txt                <- contains the single word: billing
```

Two different things are called "layout" here — keep them apart:

| | what it is | what it contains |
|---|---|---|
| `invoice_paid/layout.txt` | a file **inside an email's directory** | the **name** of the group the email belongs to — `billing` — and nothing else |
| `_layout-billing/`, `_header-billing/`, `_footer-billing/` | **directories** next to the emails | the group's **markup**, in `html[.locale].html`, like `_layout/` |

Each of the group's parts falls back on its own: no `_header-billing` → the
shared `_header` → PhoenixKit's header. A group may therefore replace only its
footer. `layout.txt` is read whole and trimmed, never per language: a group
belongs to the email, not to a translation.

Code can pick the group too, which wins over `layout.txt`:

```elixir
PhoenixKit.Mailer.send_from_template("invoice_paid", email, vars,
  defaults: fn -> %{subject: gettext("Invoice paid"), markdown: gettext("…")} end,
  layout: "billing"
)
```

A group name that is not `[a-z0-9-]+` is ignored (the shared layout is used)
and logged as a warning.

### Sending one email without the layout

```elixir
PhoenixKit.Mailer.send_from_template("export_ready", email, vars,
  defaults: fn -> %{subject: gettext("Your export"), text: gettext("…")} end,
  layout: false
)
```

With `layout: false` a text-only email is sent as plain text, an `html`
part is sent exactly as written, and a `markdown` part is sent as the bare
HTML it renders to. Your `text.txt` does not become HTML here, so if the
email has a default `html` or `markdown`, that still makes the HTML version
— override `markdown.md` or `html.html` to change both.

### Using the header and footer in your own document

Code that builds its own document — a module's newsletter wrapper, say —
can still show the site's header and footer.
`PhoenixKit.Email.Layout.render_parts/2` renders those two parts on their
own. It chooses them the same way the layout does: the group's file, then
the shared one, then PhoenixKit's; the reader's language file first; an
empty file counts as missing. It takes the layout's `:locale`, `:paths`,
`:group` and `:branding` options. Without `:paths` it reads the same
directories as every email (`config :phoenix_kit, template_paths:`, else the
host app's `priv/phoenix_kit_templates`); pass `paths: []` for PhoenixKit's
own parts only.

```elixir
alias PhoenixKit.Email.Layout
alias PhoenixKit.Templates.Substitution

parts = Layout.render_parts(subject, locale: "de", group: "newsletters")

variables =
  Map.merge(parts.variables, %{
    "header" => parts.header,
    "footer" => parts.footer,
    "content" => body_html
  })

Substitution.substitute(wrapper_html, variables, escape: true)
```

- `parts.header` and `parts.footer` are HTML. Place them with three braces
  (`{{{header}}}`, `{{{footer}}}`).
- `parts.variables` are the variables the parts were rendered with, from
  the table above: `subject`, `site_name`, `site_url`, `logo_url`,
  `accent_color`, plus any other key of a `:branding` map you pass, as
  given. They are **raw text, not HTML**: nothing in them is escaped. Write
  them with two braces (`{{site_name}}`) and substitute with
  `escape: true`, as above. Only `header` and `footer` take three.
- `parts.sources` says which file each part came from (`{:file, path}`),
  or `:default` for PhoenixKit's own. Its `ignored` list names the files
  passed over on the way, such as an empty `_header`.

A wrapped email's header and footer are chosen by the same code, so the
two cannot differ.

## Branding: logo and accent colour

Two variables carry the site's branding into every part — the layout, the
header, the footer and the body:

- `{{logo_url}}` — the project logo already set under **Settings** (the
  project logo, else the site icon), as an absolute URL with a permanent
  signed token, so it still loads in an email opened weeks later. Empty when
  there is no logo, when the file is in the trash or no longer exists, and
  when the logo is stored in a **private** library — such a file only gets
  URLs that expire, which would break in an old email. PhoenixKit's header
  shows the site's name instead.
- `{{accent_color}}` — the `email_accent_color` setting, a six-digit hex
  colour (`#1d4ed8`). Anything else, or nothing, reads as the neutral
  `#18181b`. Markdown buttons and links use it, and PhoenixKit's layout draws
  its top bar in it — only while the setting holds a colour, so a site that
  never set one keeps the look it had.

Both are set in the admin, on **Settings → Emails Transactional → Branding**
(`/admin/settings/email-sending`): the accent colour is a field there
(`#RRGGBB`, checked when saved; blank means the neutral default), and the
logo, the site name and the site URL are edited under **Settings → General**,
which that tab links to.

Both are read on every send: a new logo or colour shows in the next email
without a restart. The code sending an email may pass either variable
itself; its value is used only when valid — a `#rrggbb` colour, an empty or
`http(s)://` logo URL — and the site's otherwise, in every part.

**Which file of the logo.** The first finished one that every email client
shows (PNG, JPEG or GIF), trying the sizes smallest first: `small`, `medium`,
`large`, then the original. A transparent logo's sizes are written as PNG —
or as WebP when the host sets `config :phoenix_kit, :variant_alpha_format,
"webp"`, which Outlook for Windows does not show; such a size is passed over,
usually for the original when that is a PNG. A logo with no such file at all
(an SVG whose sizes are WebP, or sizes still being made) gives no URL. Sizes
made before transparent images were written as PNG are JPEG: such a logo
arrives on a white background until its sizes are regenerated.

## Previewing emails

**Settings → Emails Transactional → Branding → Preview emails**
(`/admin/settings/email-sending/preview`) lists every email the site knows
and renders the chosen one in any enabled language, with sample values: the
subject, the HTML (in a sandboxed frame) and the text, exactly as a send
would build them. For every part — subject, HTML, Markdown, text, the layout
group, the layout, the header and the footer — it says where it came from:

- **Database template** — an active row of the emails module answers the
  name; it wins over files until it is deactivated.
- **Host file**, with the file's path.
- **Empty file, ignored** — a file was found but is blank, so it counts as
  missing.
- **Built-in default** — PhoenixKit's (or the module's) own copy.
- **Set by the sending code** — for the layout group: the code passes
  `layout: "<group>"`, which wins over any `layout.txt`, so no file changes it.
- **Not used** — the part plays no role in this email: no such file or
  default, or, for the layout group, layout, header and footer, the email is
  sent without the layout (`layout: false`, or a whole HTML document).

Next to each part it names the file to create to override it, as a path in
the host application's source tree (`priv/phoenix_kit_templates/…`): the file
ships with the code — one added on the server is lost on the next deploy.
Placeholders that no sample value binds are listed, so a typo such as
`{{confirm_url}}` shows before a reader sees it.

A module adds its own emails to the list with the optional
`email_templates/0` callback of `PhoenixKit.Module` — the template name it
sends, a label, the same `defaults` function its send uses, sample
`variables` and the `layout` option it passes (see
`PhoenixKit.Email.Catalog`).

## A complete example

```
priv/phoenix_kit_templates/
├── _header/
│   └── html.html                 <- the logo and a tagline, every email
├── _footer/
│   ├── html.html                 <- address and unsubscribe note
│   └── html.de.html              <- … in German
├── _layout-billing/
│   └── html.html                 <- invoices: a wider document
├── _footer-billing/
│   └── html.html                 <- invoices: legal details
├── register/
│   ├── subject.de.txt            <- "Bitte bestätigen Sie Ihr Konto"
│   ├── markdown.md               <- English body, with a button
│   └── markdown.de.md            <- German body, with a button
└── invoice_paid/
    ├── layout.txt                <- billing
    └── markdown.md
```

A German reader of `register` gets the German subject and body (HTML with a
button, plain text with `Konto bestätigen: https://…`), the shared header, the
German footer and PhoenixKit's layout. `invoice_paid` gets the billing
layout and footer, and still the shared header — there is no
`_header-billing`.
