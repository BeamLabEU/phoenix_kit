defmodule PhoenixKitWeb.Live.Settings.EmailPreview do
  @moduledoc """
  Admin preview of every email the system knows (`/admin/settings/email-sending/preview`).

  Lists `PhoenixKit.Email.Catalog.entries/0` — core's emails and those
  enabled modules declare — and renders the chosen one in a chosen language
  with sample variables, through the same resolution a real send uses
  (`PhoenixKit.Email.Catalog.preview/3`). For every part it says where the
  content came from — the database template, a host file (with its path), or
  the built-in default — and which file to create to override it.

  The HTML is shown in an `<iframe srcdoc>` with an empty `sandbox`: a
  database template's HTML is operator-authored and may carry anything, and
  an empty sandbox runs no script and reaches nothing of the admin page.

  `?email=<name>&lang=<code>` selects the email and language, so a preview
  can be linked to. Not `locale`: that is the admin routes' own path
  parameter, which would shadow it. Gated like the Emails Transactional page (`settings`).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @base_path "/admin/settings/email-sending/preview"

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Email preview"))
      |> assign(
        :page_subtitle,
        gettext(
          "Every email the site sends, rendered with sample values, and where each part comes from"
        )
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:page_crumbs, [
        %{
          label: gettext("Emails Transactional"),
          path: Routes.path("/admin/settings/email-sending")
        }
      ])
      |> assign(:project_title, Settings.get_project_title())
      |> assign(
        :current_path,
        Routes.path(@base_path, locale: socket.assigns.current_locale_base)
      )
      |> assign(:entries, Catalog.entries())
      |> assign(:locales, preview_locales())
      |> assign(:override_roots, Content.override_paths())

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    entries = socket.assigns.entries
    # Core's eight entries are always listed, so there is always one to show.
    entry = Enum.find(entries, &(&1.name == params["email"])) || hd(entries)

    locale =
      if Enum.any?(socket.assigns.locales, &(elem(&1, 0) == params["lang"])),
        do: params["lang"],
        else: socket.assigns.locales |> List.first() |> elem(0)

    {:noreply,
     socket
     |> assign(:entry, entry)
     |> assign(:locale, locale)
     |> assign_preview()}
  end

  def handle_event("select_locale", %{"locale" => locale}, socket) when is_binary(locale) do
    {:noreply, push_patch(socket, to: preview_path(socket.assigns.entry, locale))}
  end

  def handle_event("select_locale", _params, socket), do: {:noreply, socket}

  defp assign_preview(socket) do
    case Catalog.preview(socket.assigns.entry, socket.assigns.locale) do
      {:ok, preview} ->
        socket |> assign(:preview, preview) |> assign(:preview_error, nil)

      {:error, message} ->
        socket |> assign(:preview, nil) |> assign(:preview_error, message)
    end
  end

  # The languages an email can be previewed in: the site's default first (what
  # a recipient with no preference gets), then the enabled site languages.
  defp preview_locales do
    default = RecipientLocale.for_rendering(nil)

    codes =
      if Languages.enabled?(),
        do: Enum.uniq([default | Languages.enabled_locale_codes()]),
        else: [default]

    Enum.map(codes, &{&1, language_label(&1)})
  end

  defp language_label(code) do
    case Languages.get_language(code) do
      %{name: name} when is_binary(name) -> "#{name} (#{code})"
      _ -> code
    end
  rescue
    _ -> code
  end

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  defp preview_path(entry, locale) do
    query = URI.encode_query(%{"email" => entry.name, "lang" => locale})
    Routes.path(@base_path) <> "?" <> query
  end

  defp owner_label(nil), do: gettext("Core")

  defp owner_label(module) do
    with true <- function_exported?(module, :module_name, 0),
         name when is_binary(name) <- module.module_name() do
      name
    else
      _ -> inspect(module)
    end
  rescue
    _ -> inspect(module)
  catch
    _kind, _reason -> inspect(module)
  end

  defp grouped_entries(entries) do
    entries
    |> Enum.chunk_by(& &1.module)
    |> Enum.map(fn [first | _] = group -> {owner_label(first.module), group} end)
  end

  # One row per part of the message and of its chrome: what it is, where it
  # came from, and which file overrides it.
  defp source_rows(%{sources: sources}, entry, locale) do
    name = entry.name
    group = sources.group

    [
      %{
        id: "subject",
        label: gettext("Subject"),
        source: sources.subject,
        used_for: [],
        file: part_file(name, "subject", "txt", locale)
      },
      %{
        id: "html",
        label: gettext("HTML body"),
        source: sources.html,
        used_for: used_for(sources, :html),
        file: part_file(name, "html", "html", locale)
      },
      %{
        id: "markdown",
        label: gettext("Markdown body"),
        source: sources.markdown,
        used_for: used_for(sources, :markdown),
        file: part_file(name, "markdown", "md", locale)
      },
      %{
        id: "text",
        label: gettext("Text body"),
        source: sources.text,
        used_for: used_for(sources, :text),
        file: part_file(name, "text", "txt", locale)
      },
      %{
        id: "layout-group",
        label: gettext("Layout group"),
        source: sources.group_from,
        value: group,
        used_for: [],
        file: group_file(name, sources)
      },
      %{
        id: "layout",
        label: gettext("Layout"),
        source: sources.layout,
        used_for: [],
        file: chrome_file(Layout.name(), group, sources.layout)
      },
      %{
        id: "header",
        label: gettext("Header"),
        source: sources.header,
        used_for: [],
        file: chrome_file(Layout.header_name(), group, sources.layout)
      },
      %{
        id: "footer",
        label: gettext("Footer"),
        source: sources.footer,
        used_for: [],
        file: chrome_file(Layout.footer_name(), group, sources.layout)
      }
    ]
  end

  # Which version of the email this part builds — a part can be found and
  # still lose to another (a host `markdown.md` over core's `text`).
  defp used_for(sources, part) do
    Enum.filter(
      [
        sources.html_from == part && {"html", gettext("Builds the HTML version")},
        sources.text_from == part && {"text", gettext("Builds the text version")}
      ],
      & &1
    )
  end

  # Which file wins, in the order `PhoenixKit.Email.Content` applies — every
  # host file before every built-in default for the HTML, so a host's
  # `text` reaches the HTML version too.
  defp html_order_note do
    gettext(
      "The HTML version comes from the first of: your %{html}, your %{markdown}, your %{text} (as paragraphs, without buttons), then the built-in HTML, Markdown and text.",
      html: "html.html",
      markdown: "markdown.md",
      text: "text.txt"
    )
  end

  defp text_order_note do
    gettext(
      "The text version comes from the first of: your %{text}, your %{markdown}, then the built-in text and Markdown. Override %{markdown} to change both versions at once.",
      markdown: "markdown.md",
      text: "text.txt"
    )
  end

  defp part_file(name, part, ext, locale), do: "#{name}/#{part}.#{base_language(locale)}.#{ext}"

  # No layout was used (sent with `layout: false`, a whole document, or no
  # HTML at all): a chrome file would change nothing.
  defp chrome_file(_chrome, _group, nil), do: nil
  defp chrome_file(chrome, nil, _layout), do: "#{chrome}/html.html"
  defp chrome_file(chrome, group, _layout), do: "#{chrome}-#{group}/html.html"

  # Why a row has no file to create.
  # A layout.txt changes nothing when the sending code names the group (the
  # option wins) or when no layout is used at all (`layout: false` ignores it).
  defp group_file(_name, %{layout: nil}), do: nil
  defp group_file(_name, %{group_from: :option}), do: nil
  defp group_file(name, _sources), do: "#{name}/layout.txt"

  defp no_file_note(%{id: "layout-group", source: :option}),
    do: gettext("Set by the sending code")

  defp no_file_note(_row), do: gettext("Not used")

  defp base_language(locale), do: locale |> String.split("-") |> hd() |> String.downcase()

  # Paths as a developer finds them in the host's source tree. The roots are
  # resolved through `Application.app_dir/1` — under `_build/` in dev, inside
  # the release in production — where a file added by hand is lost on the
  # next build or deploy; the file belongs in the host's `priv/` and ships
  # with the code.
  defp override_file([], file), do: file
  defp override_file([root | _], file), do: Path.join(display_root(root), file)

  defp display_root(root) do
    if root == "priv/phoenix_kit_templates" or
         String.ends_with?(root, "/priv/phoenix_kit_templates"),
       do: "priv/phoenix_kit_templates",
       else: Path.relative_to_cwd(root)
  end

  defp display_path(path, roots) do
    Enum.find_value(roots, path, fn root ->
      case Path.relative_to(path, root) do
        ^path -> nil
        relative -> Path.join(display_root(root), relative)
      end
    end)
  end

  defp source_badge(assigns) do
    ~H"""
    <%= case @source do %>
      <% :db -> %>
        <span class="badge badge-warning badge-sm">{gettext("Database template")}</span>
      <% {:file, _path} -> %>
        <span class="badge badge-info badge-sm">{gettext("Host file")}</span>
      <% {:blank_file, _path} -> %>
        <span class="badge badge-ghost badge-sm">{gettext("Empty file, ignored")}</span>
      <% :default -> %>
        <span class="badge badge-neutral badge-sm">{gettext("Built-in default")}</span>
      <% :option -> %>
        <span class="badge badge-neutral badge-sm">{gettext("Set by the sending code")}</span>
      <% _ -> %>
        <span class="text-base-content/40">{gettext("Not used")}</span>
    <% end %>
    """
  end

  defp source_path({:file, path}), do: path
  defp source_path({:blank_file, path}), do: path
  defp source_path(_source), do: nil

  defp ignored_reason(:blank_file), do: gettext("empty file")

  defp ignored_reason(:no_content),
    do: gettext("layout does not place the content placeholder")

  defp ignored_reason(_reason), do: gettext("ignored")

  defp missing_line(missing) do
    Enum.map_join(missing, "; ", fn {part, names} ->
      "#{part}: " <> Enum.map_join(names, ", ", &("{{" <> &1 <> "}}"))
    end)
  end
end
