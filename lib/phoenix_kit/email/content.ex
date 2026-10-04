defmodule PhoenixKit.Email.Content do
  @moduledoc """
  Resolves the content of one outbound message: subject, text, and optional HTML.

  Every auth email in core goes through here, so the layering below is decided
  once rather than per message.

  ## Layers, most specific first

  1. **A database template** from the emails package, when one is active under
     this name. Transitional — the template table is being retired (see
     `dev_docs/plans/2026-09-06-filesystem-templates.md`), but it is the only
     customization mechanism installs have today, and it must keep winning until
     the export task has shipped and operators have moved their edits to files.
     Removing it before then would silently revert every customized message.
  2. **A host override file**, resolved by `PhoenixKit.Templates` across the
     recipient's locale, its base language, and a locale-less fallback.
  3. **Core's own default**, a Gettext call evaluated in the recipient's locale.

  Layers 2 and 3 combine per part, so a host that overrides only the body keeps
  core's translated subject.

  ## What a host override looks like on disk

  The template **name is a directory**; the files inside it are named for the
  part they supply, optionally carrying a locale. To rewrite the body of the
  new-login alert, a host adds:

      <host>/priv/phoenix_kit_templates/
      └── new_login_alert/            <- the template name (a directory)
          ├── text.txt                <- <part>.<ext>
          └── text.de.txt             <- <part>.<locale>.<ext>

  `subject`, `text` and `layout` are `.txt`, `html` is `.html`, `markdown` is
  `.md`. That host now has its own body in German and a locale-less fallback
  for everyone else, while the subject still comes from core's Gettext
  default in all seven languages — parts resolve independently.

  Roots come from `override_paths/0`. Full rules, including precedence and the
  path-safety constraints on `name`, live in `PhoenixKit.Templates`.

  ## Which part makes which body

  Five parts are resolved: `subject`, `text`, `html`, `markdown` and `layout`
  (the email's layout group, below). `markdown` and `layout` never leave this
  module — the result is always `subject`, `text`, `html`.

  Each part comes from a host file if there is one, else from the caller's
  defaults. Each body then takes the first match, in this order:

  | | HTML body | text body |
  |---|---|---|
  | 1 | host `html` | host `text` |
  | 2 | host `markdown`, rendered | host `markdown`, as text |
  | 3 | host `text`, escaped into paragraphs | default `text` |
  | 4 | default `html` | default `markdown`, as text |
  | 5 | default `markdown`, rendered | |
  | 6 | default `text`, escaped into paragraphs | |

  For the HTML body every host part outranks every default: a host that
  overrides only `text.txt` gets its own words in the HTML too, rather than
  an HTML version built from the caller's `markdown` or `html` default that
  no longer says what the text does. Markdown feeds both bodies, so a host's
  `markdown.md` replaces the default copy in the HTML and in the text alike.
  A host's `text` builds the HTML only from escaped paragraphs (addresses
  linked, no buttons) — a host that wants buttons or a module's richer HTML
  overrides `markdown.md` or `html.html` instead. Markdown is rendered by
  `PhoenixKit.Email.Markdown` (buttons, accent-coloured links); text is
  escaped into paragraphs by `Layout.text_to_html/1`.

  > Earlier releases put a host's `text` after the defaults for the HTML
  > body (`html` default, then `markdown` default). The order matters only
  > for an email whose caller ships an `html` or `markdown` default *and*
  > whose host overrides `text` alone — which core's own emails began to be
  > when their defaults became Markdown.

  **With `layout: false`** a host's `text` builds no HTML (see "The
  layout"), so its row is skipped and the HTML comes from the caller's
  `html` or `markdown` default, if there is one, while the text body is the
  host's. A caller that sends without the layout and ships an `html` or
  `markdown` default keeps the two versions in step only through a host's
  `markdown.md` or `html.html`.

  A blank `html`, `text` or `markdown` (an empty override file, whitespace
  only) counts as no part, with or without the layout, so an empty
  `html.html` never sends an empty body: the next part in line is used.

  Every part on this path also sees `{{logo_url}}` and `{{accent_color}}`
  (`PhoenixKit.Email.Branding`); a variable the caller passes under the same
  name wins when it is valid (a `#rrggbb` colour, an empty or `http(s)://`
  logo URL) and is replaced by the site's otherwise.

  ## The layout

  The HTML body is wrapped in the shared layout, `PhoenixKit.Email.Layout`,
  with its header and footer — each of which a host overrides with its own
  `_layout`, `_header` or `_footer` file. Only the `html` part changes;
  `subject` and `text` are returned as built above.

    * a fragment — it is wrapped.
    * a whole document (`<!doctype …` or `<html …`, after any BOM,
      whitespace, comments or XML prolog; `Layout.document?/1`) — it is left
      alone; it already carries its own chrome.
    * no `html`, `markdown` or `text` — nothing to wrap, `html` stays `nil`.
    * `layout: false` — nothing is wrapped, and a text-only message stays
      text-only (`html` is `nil`). A host's `text` then builds no HTML at
      all, so the HTML body may still come from the caller's `html` or
      `markdown` default (see "Which part makes which body").

  **Groups.** `layout: "billing"` wraps the message in the `billing` group's
  chrome (`_layout-billing`, `_header-billing`, `_footer-billing`, each
  falling back to the shared one). Without the option, the email's own
  `layout.txt` names the group — its content is the group name, nothing
  else.

  A database template (layer 1) is never wrapped.

  ## Sources, for a preview

  `resolve_with_sources/5` resolves exactly as `resolve/5` and also says
  where each part, the layout, the header and the footer came from.

  ## Why the default is a function

  `defaults` is a zero-arity function, not a map, because it is evaluated
  *inside* the recipient's locale — and because layer 1 short-circuits it
  entirely. Passing a map would translate content that a database template is
  about to discard.
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Email.Markdown
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Templates
  alias PhoenixKit.Utils.RecipientLocale

  require Logger

  # Which part each body comes from, first match wins. For the HTML every host
  # part outranks every default, so a host that rewrote only `text.txt` is not
  # sent an HTML version built from the caller's Markdown (or html) default
  # that says something else. Markdown feeds both bodies.
  @html_order [
    {:file, :html},
    {:file, :markdown},
    {:file, :text},
    {:default, :html},
    {:default, :markdown},
    {:default, :text}
  ]

  @text_order [
    {:file, :text},
    {:file, :markdown},
    {:default, :text},
    {:default, :markdown}
  ]

  @typedoc """
  Resolved content plus the database template it came from, if any.

  `db_template` is `nil` on the file/default path and is handed back so the
  caller can record usage against the row it used.
  """
  @type resolved :: %{
          subject: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          db_template: map() | nil
        }

  @typedoc """
  Where one part was found.

    * `:db` — the active database template.
    * `{:file, path}` — a host override file.
    * `{:blank_file, path}` — a host file that is empty or whitespace only,
      which counts as no part at all (it does **not** fall back to the
      default).
    * `:default` — the caller's default (core's Gettext copy, or a module's).
  """
  @type source :: :db | :default | {:file, Path.t()} | {:blank_file, Path.t()}

  @typedoc """
  Where everything in one resolved message came from — for a preview screen.

    * `subject`, `text`, `html`, `markdown` — where each part was found;
      `nil` when nowhere.
    * `html_from` — what the HTML body was built from: `:html`, `:markdown`,
      `:text` (escaped into paragraphs), or `nil` (no HTML body).
    * `text_from` — what the text body is: `:text`, `:markdown` (converted),
      or `nil`.
    * `group`, `group_from` — the layout group and where it was named:
      `:option` (`layout: "<group>"`), or the source of the `layout` part.
    * `layout`, `header`, `footer`, `ignored` — see
      `t:PhoenixKit.Email.Layout.sources/0`; `nil` (and `[]`) when nothing
      was wrapped.
  """
  @type sources :: %{
          subject: source() | nil,
          text: source() | nil,
          html: source() | nil,
          markdown: source() | nil,
          html_from: :html | :markdown | :text | nil,
          text_from: :text | :markdown | nil,
          group: String.t() | nil,
          group_from: :option | source() | nil,
          layout: Layout.source() | nil,
          header: Layout.source() | nil,
          footer: Layout.source() | nil,
          ignored: [{:blank_file | :no_content, Path.t()}]
        }

  @doc """
  Resolves `name` for `recipient`.

  `recipient` is anything `PhoenixKit.Utils.RecipientLocale` understands — a
  user struct, or a bare email string where no account exists yet. `variables`
  are substituted into whichever layer wins.

  ## Options

    * `:locale` — overrides the locale resolved from `recipient`, for a
      caller whose recipient is a bare address that carries no preference,
      such as `PhoenixKit.Mailer.send_from_template/4`.
    * `:paths` — overrides the override roots, which is how a test points at
      a fixture directory; defaults to `override_paths/0`.
    * `:layout` — `false` skips the shared layout (see "The layout" above);
      a group name (`"billing"`) wraps the message in that group's layout,
      over whatever the email's `layout` part names. Defaults to `true`.
  """
  @spec resolve(String.t(), term(), map(), (-> Templates.defaults()), keyword()) :: resolved()
  def resolve(name, recipient, variables, defaults, opts \\ [])
      when is_binary(name) and is_function(defaults, 0) do
    name |> resolve_with_sources(recipient, variables, defaults, opts) |> elem(0)
  end

  @doc """
  `resolve/5`, plus where every part of the result came from.

  The same resolution as a send, so a preview built on it cannot show a
  different source from the one a real email would use. See `t:sources/0`.
  """
  @spec resolve_with_sources(String.t(), term(), map(), (-> Templates.defaults()), keyword()) ::
          {resolved(), sources()}
  def resolve_with_sources(name, recipient, variables, defaults, opts \\ [])
      when is_binary(name) and is_function(defaults, 0) do
    locale = Keyword.get(opts, :locale) || RecipientLocale.for_rendering(recipient)
    paths = Keyword.get(opts, :paths) || override_paths()

    case Provider.current().get_active_template_by_name(name) do
      nil ->
        resolve_files(name, variables, RecipientLocale.in_locale(locale, defaults),
          locale: locale,
          paths: paths,
          layout: Keyword.get(opts, :layout, true)
        )

      template ->
        rendered = Provider.current().render_template(template, variables, locale)

        # A provider answers in ITS shape: core's own `DefaultProvider` returns
        # `%{subject:, html_body:, text_body:}`, and `phoenix_kit_emails`
        # validates exactly those three keys on every render. Normalising both
        # bodies here is what lets each consumer read `.text`/`.html` whichever
        # branch produced the content — reading `rendered.text` raised a
        # KeyError on every send that found a template in the database.
        resolved = %{
          subject: rendered.subject,
          text: rendered.text_body,
          html: rendered.html_body,
          db_template: template
        }

        {resolved, db_sources(resolved)}
    end
  end

  # Layers 2 and 3. `defaults` is already evaluated in the recipient's locale.
  defp resolve_files(name, variables, defaults, opts) do
    template_opts = Keyword.take(opts, [:locale, :paths])
    accent = Branding.configured_accent_color()

    branding = %{
      "logo_url" => Branding.logo_url(),
      "accent_color" => accent || Branding.default_accent_color()
    }

    variables = variables |> stringify_keys() |> Branding.merge(branding)

    rendered = Templates.render(name, defaults, variables, template_opts)
    found = Templates.sources(name, defaults, template_opts)

    # A blank part (an empty override file) is no part, with or without the
    # layout, so whether a message exists never depends on the layout.
    parts = Map.new([:html, :text, :markdown, :layout], &{&1, present(Map.get(rendered, &1))})

    wrap? = opts[:layout] != false
    {text, text_from} = first_body(@text_order, parts, found, &text_body(&1, parts, variables))
    {group, group_from} = group(opts[:layout], parts.layout, found)

    {html, html_from} =
      first_body(@html_order, parts, found, &html_body(&1, parts, wrap?, variables))

    {html, chrome} =
      wrap(html, rendered.subject, wrap?,
        locale: opts[:locale],
        paths: opts[:paths],
        group: group,
        # What the body saw, so a caller's own `accent_color` reaches the
        # layout's bar and the header too.
        branding: Map.take(variables, Map.keys(branding)),
        accent_bar: accent != nil
      )

    sources =
      %{
        subject: Map.get(found, :subject),
        text: part_source(found, rendered, :text),
        html: part_source(found, rendered, :html),
        markdown: part_source(found, rendered, :markdown),
        html_from: html_from,
        text_from: text_from,
        group: group,
        group_from: group_from
      }
      |> Map.merge(chrome)

    {%{subject: rendered.subject, text: text, html: html, db_template: nil}, sources}
  end

  # A body from the first entry of the order whose part was found in that
  # layer and builds into something — Markdown that renders to nothing (only
  # raw HTML, which is dropped) gives way to the next entry, as a blank file
  # does. See "Which part makes which body" above.
  defp first_body(order, parts, found, build) do
    Enum.find_value(order, {nil, nil}, fn {layer, part} ->
      if is_binary(parts[part]) and layer(found[part]) == layer do
        case build.(part) do
          {nil, _from} -> nil
          body -> body
        end
      end
    end)
  end

  defp layer({:file, _path}), do: :file
  defp layer(:default), do: :default
  defp layer(_none), do: nil

  # The text body: the `text` part, or the `markdown` part as plain text.
  defp text_body(:text, parts, _variables), do: {parts.text, :text}

  defp text_body(:markdown, parts, variables),
    do: built(Markdown.to_text(parts.markdown, variables), :markdown)

  # The HTML body before the layout: the `html` part, the `markdown` part
  # rendered, or — only when it is about to be wrapped — the text escaped into
  # paragraphs. Without the layout a text-only message stays text-only.
  defp html_body(:html, parts, _wrap?, _variables), do: {parts.html, :html}

  defp html_body(:markdown, parts, _wrap?, variables),
    do: built(Markdown.to_html(parts.markdown, variables), :markdown)

  defp html_body(:text, parts, true, _variables), do: {Layout.text_to_html(parts.text), :text}
  defp html_body(_part, _parts, _wrap?, _variables), do: {nil, nil}

  defp built(body, from) do
    case present(body) do
      nil -> {nil, nil}
      body -> {body, from}
    end
  end

  # Only the html is wrapped: subject and text reach the reader exactly as
  # resolved. With no HTML there is nothing to wrap, and leaving html nil is
  # what keeps an unknown name answering `{:error, :template_not_found}` in
  # `Mailer.send_from_template/4`. A whole document already has its chrome.
  defp wrap(nil, _subject, _wrap?, _opts), do: {nil, no_chrome()}
  defp wrap(html, _subject, false, _opts), do: {html, no_chrome()}

  defp wrap(html, subject, true, opts) do
    if Layout.document?(html), do: {html, no_chrome()}, else: Layout.render(html, subject, opts)
  end

  defp no_chrome, do: %{layout: nil, header: nil, footer: nil, ignored: []}

  # The group: the caller's `layout: "<group>"`, else the email's `layout`
  # part, else none. An invalid name is no group, and a warning in the log
  # (once per name).
  defp group(false, _part, _found), do: {nil, nil}

  defp group(option, _part, _found) when is_binary(option),
    do: valid_group(option, :option)

  defp group(_option, part, found) when is_binary(part),
    do: valid_group(part, Map.get(found, :layout))

  defp group(_option, _part, _found), do: {nil, nil}

  defp valid_group(group, from) do
    if Layout.valid_group?(group) do
      {group, from}
    else
      warn_once_invalid_group(group)
      {nil, nil}
    end
  end

  # A bad `layout.txt` is read on every send of its email; one warning per
  # name is enough. Names come from files and code, so the keys are bounded;
  # the cap keeps a pathological one from becoming a large key.
  defp warn_once_invalid_group(group) do
    key = {__MODULE__, :warned_invalid_group, binary_part(group, 0, min(byte_size(group), 64))}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Email layout group #{inspect(group)} is not a valid group name ([a-z0-9-]+); " <>
          "using the shared layout"
      )
    end
  end

  # Where a part was found — a file that resolved blank is reported as such,
  # because it suppresses the part rather than falling back to the default.
  defp part_source(found, rendered, part) do
    present? = present(Map.get(rendered, part)) != nil

    case Map.get(found, part) do
      {:file, path} when not present? -> {:blank_file, path}
      :default when not present? -> nil
      source -> source
    end
  end

  defp db_sources(resolved) do
    %{
      subject: if(resolved.subject, do: :db),
      text: if(resolved.text, do: :db),
      html: if(resolved.html, do: :db),
      markdown: nil,
      html_from: if(resolved.html, do: :html),
      text_from: if(resolved.text, do: :text),
      group: nil,
      group_from: nil
    }
    |> Map.merge(no_chrome())
  end

  defp present(part) do
    if is_binary(part) and String.trim(part) != "", do: part
  end

  # Branding is merged under the caller's variables (`Branding.merge/2`: a
  # caller's own valid `accent_color`/`logo_url` wins); string keys on both
  # sides make that merge well-defined whichever key type the caller used.
  defp stringify_keys(variables) when is_map(variables),
    do: Map.new(variables, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_variables), do: %{}

  @doc """
  Roots searched for host override files, most specific first.

  `config :phoenix_kit, template_paths: [...]` wins; otherwise the host
  application's own `priv/phoenix_kit_templates`. An empty list means core's
  defaults are used verbatim, which is the correct answer for a host that has
  never written an override — and for a mix task running before the host
  application is loaded.
  """
  @spec override_paths() :: [Path.t()]
  def override_paths do
    case Config.get(:template_paths) do
      {:ok, paths} when is_list(paths) -> paths
      _ -> parent_app_paths()
    end
  end

  defp parent_app_paths do
    case Config.get_parent_app() do
      app when is_atom(app) and not is_nil(app) -> app_template_dir(app)
      _ -> []
    end
  end

  # `Application.app_dir/1` raises for an application that is not loaded, which
  # is the normal state inside `mix phoenix_kit.install` — no overrides is the
  # right answer there, not a crash on the way to sending nothing.
  defp app_template_dir(app) do
    [Path.join(Application.app_dir(app), "priv/phoenix_kit_templates")]
  rescue
    ArgumentError -> []
  end
end
