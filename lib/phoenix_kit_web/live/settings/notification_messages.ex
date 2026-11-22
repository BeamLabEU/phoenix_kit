defmodule PhoenixKitWeb.Live.Settings.NotificationMessages do
  @moduledoc """
  Settings → Notification messages (`/admin/settings/notification-messages`):
  the wording of notification emails and Telegram messages, per notification
  type and language (item 20 of the boss's fourth Projects list, decided
  with Max on 2026-11-20). The store and its rules are
  `PhoenixKit.Notifications.Messages`.

  On the left, "Every notification" and each type with its sub-types. On the
  right, for the chosen type, channel and language:

    * the parts — the email's subject and body (Markdown), or the Telegram
      text — starting from what the reader gets today when nothing is saved;
    * the variables the channel offers;
    * a live preview with sample values, through the same resolution a real
      send uses (the email in an `<iframe srcdoc>` with an empty sandbox);
    * Save, and "Reset to default", which deletes the saved wording;
    * a notice when the default changed since the wording was saved;
    * which languages have their own wording.

  `?type=…&channel=…&lang=…` selects; not `locale`, which is the admin
  routes' own path parameter. Gated by `settings.messages` (the Owner
  always): on mount, and again on every event against the scope as it is
  now, so a right taken away mid-session changes nothing.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Notifications.Channels.Telegram
  alias PhoenixKit.Notifications.Messages
  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @base_path "/admin/settings/notification-messages"

  @impl true
  def mount(_params, _session, socket) do
    if Messages.may_edit?(socket.assigns[:phoenix_kit_current_scope]) do
      {:ok,
       socket
       |> attach_hook(:notification_messages_gate, :handle_event, &gate/3)
       |> assign(:page_title, gettext("Notification messages"))
       |> assign(
         :page_subtitle,
         gettext("The wording of notification emails and Telegram messages, in each language")
       )
       |> assign(:page_section, gettext("Settings"))
       |> assign(:page_section_path, Routes.path("/admin/settings"))
       |> assign(:page_crumbs, [])
       |> assign(:project_title, Settings.get_project_title())
       |> assign(:current_path, Routes.path(@base_path))
       |> assign(:types, type_rows())
       |> assign(:locales, locales())
       |> assign_push_settings()
       |> assign(:notice, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: Routes.path("/admin/settings"))}
    end
  end

  # Every event asks again, against the scope as it is now (core swaps it in
  # place when grants change).
  defp gate(_event, _params, socket) do
    if Messages.may_edit?(socket.assigns[:phoenix_kit_current_scope]),
      do: {:cont, socket},
      else:
        {:halt, put_flash(socket, :error, gettext("You may not change notification wording."))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    type = pick(params["type"], Enum.map(socket.assigns.types, & &1.key), Messages.all_types())
    channel = pick(params["channel"], Messages.channels(), "email")

    locale =
      pick(params["lang"], Enum.map(socket.assigns.locales, &elem(&1, 0)), first_locale(socket))

    {:noreply,
     socket
     |> assign(type: type, channel: channel, locale: locale, notice: nil)
     |> load()}
  end

  defp pick(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  defp first_locale(socket), do: socket.assigns.locales |> List.first() |> elem(0)

  # Each part as a reader of this type and language gets it today: its own
  # saved wording, else what it inherits (its base language, its base
  # type, "Every notification"), else the default — and where it came from,
  # so a save keeps only what was changed and an untouched inherited part
  # goes on inheriting (codex, 2026-11-20).
  defp load(socket) do
    %{type: type, channel: channel, locale: locale} = socket.assigns
    entry = Messages.entry(type, channel, locale)
    inherited = Messages.for_message(type, channel, locale, inherited_only: true)
    defaults = Messages.default_parts(channel, locale)

    {fields, sources} =
      Messages.parts(channel)
      |> Enum.map(fn part ->
        cond do
          own?(entry, part) -> {{part, entry[part]}, {part, :own}}
          is_binary(inherited[part]) -> {{part, inherited[part]}, {part, :inherited}}
          true -> {{part, defaults[part] || ""}, {part, :default}}
        end
      end)
      |> Enum.unzip()

    fields = Map.new(fields)

    socket
    |> assign(:inherited, inherited)
    |> assign(:entry, entry)
    |> assign(:fields, fields)
    |> assign(:start, fields)
    |> assign(:sources, Map.new(sources))
    |> assign(:defaults, defaults)
    |> assign(:edited, Messages.edited_locales(type, channel))
    |> assign(:drifted?, drifted?(entry, channel, locale))
    |> assign_preview()
  end

  defp own?(%{} = entry, part), do: is_binary(entry[part]) and String.trim(entry[part]) != ""
  defp own?(_entry, _part), do: false

  # What a save stores: the parts this type has of its own, and any other
  # part the editor changed. An untouched inherited or default part is left
  # blank, so it keeps falling back.
  defp to_store(fields, socket) do
    %{start: start, sources: sources} = socket.assigns

    # A textarea hands back `\n` for `\r\n`: the same text (codex).
    same? = fn a, b -> normalize(a) == normalize(b) end

    Map.new(fields, fn {part, value} ->
      if sources[part] != :own and same?.(value, start[part]),
        do: {part, ""},
        else: {part, value}
    end)
  end

  defp submitted_parts(fields, channel) do
    fields
    |> Map.take(Messages.parts(channel))
    |> Map.filter(fn {_part, value} -> is_binary(value) end)
  end

  defp normalize(text) when is_binary(text),
    do: text |> String.replace("\r\n", "\n") |> String.trim()

  defp normalize(_), do: ""

  defp drifted?(nil, _channel, _locale), do: false

  defp drifted?(entry, channel, locale),
    do: entry["default_hash"] != Messages.default_hash(channel, locale)

  @impl true
  def handle_event("select", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         messages_path(
           params["type"] || socket.assigns.type,
           params["channel"] || socket.assigns.channel,
           params["lang"] || socket.assigns.locale
         )
     )}
  end

  def handle_event("change", %{"message" => fields}, socket) when is_map(fields) do
    fields = submitted_parts(fields, socket.assigns.channel)

    {:noreply,
     socket |> assign(:fields, Map.merge(socket.assigns.fields, fields)) |> assign_preview()}
  end

  def handle_event("save", %{"message" => fields} = params, socket) when is_map(fields) do
    %{type: type, channel: channel, locale: locale} = socket.assigns
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Every part, the submitted ones over what the editor holds: a partial
    # payload never drops a part (codex). The version always goes: an
    # editor never saves unchecked.
    stored =
      socket.assigns.fields
      |> Map.merge(submitted_parts(fields, channel))
      |> to_store(socket)

    case Messages.save(scope, type, channel, locale, stored, version: params["version"] || "0") do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, gettext("Saved."))}

      {:error, :empty} when is_nil(socket.assigns.entry) ->
        {:noreply, put_flash(socket, :info, gettext("Nothing changed."))}

      # Every own part cleared: the same as a reset (codex).
      {:error, :empty} ->
        reset(socket, params["version"] || "0")

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(
           :fields,
           Map.merge(socket.assigns.fields, submitted_parts(fields, channel))
         )
         |> assign(:notice, error_text(reason))}
    end
  end

  def handle_event("reset", _params, socket) do
    reset(socket, (socket.assigns.entry || %{})["version"] || 0)
  end

  # Browser push, site-wide (`PhoenixKit.Notifications.Push`): on or off,
  # the line on a locked screen or not, the grouping window.
  def handle_event("push_settings", %{"push" => push} = _params, socket) when is_map(push) do
    actor = socket.assigns[:phoenix_kit_current_scope] |> Scope.user_uuid()
    opts = [actor_uuid: actor, source: "settings"]

    seconds =
      case Integer.parse(if is_binary(push["group_seconds"]), do: push["group_seconds"], else: "") do
        {n, ""} -> n |> max(5) |> min(600)
        _ -> Push.group_seconds()
      end

    result =
      RepoHelper.repo().transact(fn ->
        with {:ok, _} <-
               Settings.update_boolean_setting_with_module(
                 "push_enabled",
                 push["enabled"] == "true",
                 "notifications",
                 opts
               ),
             {:ok, _} <-
               Settings.update_boolean_setting_with_module(
                 "push_show_line",
                 push["show_line"] == "true",
                 "notifications",
                 opts
               ) do
          Settings.update_setting_with_module(
            "push_group_seconds",
            Integer.to_string(seconds),
            "notifications",
            opts
          )
        end
      end)

    socket = assign_push_settings(socket)

    case result do
      {:ok, _} -> {:noreply, put_flash(socket, :info, gettext("Saved."))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Failed to save settings"))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp reset(socket, version) do
    %{type: type, channel: channel, locale: locale} = socket.assigns
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Messages.reset(scope, type, channel, locale, version: version) do
      :ok -> {:noreply, socket |> load() |> put_flash(:info, gettext("Back to the default."))}
      {:error, reason} -> {:noreply, assign(socket, :notice, error_text(reason))}
    end
  end

  defp assign_push_settings(socket) do
    assign(socket, :push, %{
      enabled: Push.enabled?(),
      show_line: Push.show_line?(),
      group_seconds: Push.group_seconds()
    })
  end

  defp error_text(:stale),
    do:
      gettext("Someone else saved this message meanwhile. Reload the page to see their version.")

  defp error_text(:empty), do: gettext("Write something, or reset to the default.")
  defp error_text(:raw_html), do: gettext("Three braces insert raw HTML; use two: {{text}}.")

  defp error_text({:too_long, part}),
    do: gettext("“%{part}” is too long.", part: part_label(part))

  defp error_text({:unknown_variables, names}),
    do:
      gettext("Unknown variables: %{names}. Use those listed beside the editor.",
        names: Enum.map_join(names, ", ", &"{{#{&1}}}")
      )

  defp error_text(:not_allowed), do: gettext("You may not change notification wording.")
  defp error_text(_), do: gettext("Could not save the message.")

  # ── Preview ───────────────────────────────────────────────────────────

  defp preview_overrides(socket) do
    edits =
      socket.assigns.fields
      |> to_store(socket)
      |> Map.reject(fn {_part, value} ->
        normalize(value) == "" or String.contains?(value, "{{{")
      end)

    Map.merge(socket.assigns.inherited, edits)
  end

  defp assign_preview(%{assigns: %{channel: "email"}} = socket) do
    locale = socket.assigns.locale

    # The editor's own text as the top layer; empty parts fall back as a
    # send's would. A raw `{{{…}}}` is never previewed (it is refused).
    overrides = preview_overrides(socket)

    content =
      Content.resolve(
        "notification",
        nil,
        sample_values(locale),
        fn -> CoreTemplates.notification_defaults() end,
        locale: locale,
        overrides: overrides
      )

    assign(socket, :preview, %{subject: content.subject, html: content.html, text: content.text})
  rescue
    _ -> assign(socket, :preview, nil)
  end

  defp assign_preview(%{assigns: %{channel: "telegram"}} = socket) do
    values = sample_values(socket.assigns.locale)

    envelope = %{
      title: values["title"],
      text: values["text"],
      quote: values["quote"],
      url: values["url"],
      reason: values["reason"],
      reason_url: values["settings_url"]
    }

    text = Telegram.render_body(envelope, preview_overrides(socket), false)

    assign(socket, :preview, %{text: text, button: values["action_label"]})
  end

  defp assign_preview(socket), do: assign(socket, :preview, nil)

  # One notice, in the editor's language, standing in for any type.
  defp sample_values(locale) do
    RecipientLocale.in_locale(locale, fn ->
      %{
        "subject" => gettext("ACME-12 can be started"),
        "title" => gettext("ACME-12 can be started"),
        "text" => gettext("Fit the doors (ACME-12) can be started"),
        "quote" => gettext("Anna: Please measure wall A again before you start."),
        "url" => Routes.base_url() <> Routes.path("/admin"),
        "action_label" => gettext("Open task"),
        "reason" => gettext("You get this because “A task of yours can be started” is on."),
        "settings_url" => Routes.base_url() <> Routes.path("/profile/settings/notifications"),
        "settings_label" => gettext("Change")
      }
    end)
  end

  # ── The lists ─────────────────────────────────────────────────────────

  defp type_rows do
    all = %{key: Messages.all_types(), label: gettext("Every notification"), sub?: false}

    rows =
      Enum.flat_map(Types.list(), fn type ->
        [%{key: type.key, label: Types.translate(type, :label), sub?: false}] ++
          for sub <- type[:sub_types] || [],
              do: %{key: sub.key, label: Types.translate(sub, :label), sub?: true}
      end)

    [all | rows]
  rescue
    _ -> [%{key: Messages.all_types(), label: gettext("Every notification"), sub?: false}]
  end

  defp locales do
    default = RecipientLocale.for_rendering(nil)

    codes =
      if Languages.enabled?(),
        do: Enum.uniq([default | Languages.enabled_locale_codes()]),
        else: [default]

    Enum.map(codes, &{&1, language_label(&1)})
  rescue
    _ -> [{"en", "en"}]
  end

  defp language_label(code) do
    case Languages.get_language(code) do
      %{name: name} when is_binary(name) -> "#{name} (#{code})"
      _ -> code
    end
  rescue
    _ -> code
  end

  defp messages_path(type, channel, lang),
    do:
      Routes.path(@base_path) <>
        "?" <> URI.encode_query(%{"type" => type, "channel" => channel, "lang" => lang})

  defp channel_label("email"), do: gettext("Email")
  defp channel_label("telegram"), do: gettext("Telegram")
  defp channel_label(other), do: other

  defp part_label("subject"), do: gettext("Subject")
  defp part_label("markdown"), do: gettext("Body (Markdown)")
  defp part_label("text"), do: gettext("Text")
  defp part_label(other), do: other

  defp variable_help("subject"), do: gettext("the title, or the start of the line")
  defp variable_help("title"), do: gettext("the short title, when the module gives one")
  defp variable_help("text"), do: gettext("the notification's line")
  defp variable_help("quote"), do: gettext("the comment it carries, with its writer")
  defp variable_help("url"), do: gettext("the link to what it is about")
  defp variable_help("action_label"), do: gettext("the button's label")
  defp variable_help("reason"), do: gettext("which setting sent it")
  defp variable_help("settings_url"), do: gettext("where the reader changes that setting")
  defp variable_help("settings_label"), do: gettext("“Change”")
  defp variable_help("logo_url"), do: gettext("the site's logo")
  defp variable_help("accent_color"), do: gettext("the site's accent colour")
  defp variable_help(_), do: ""

  defp type_label(types, key),
    do: Enum.find_value(types, key, &(&1.key == key && &1.label))

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={@page_subtitle}
      page_section={@page_section}
      page_section_path={@page_section_path}
      page_crumbs={@page_crumbs}
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="flex flex-col lg:flex-row gap-6 px-4 py-6">
        <aside class="lg:w-72 shrink-0" aria-label={gettext("Notification types")}>
          <ul id="notification-messages-types" class="menu w-full bg-base-100 rounded-box shadow">
            <li :for={row <- @types}>
              <.link
                id={"notification-messages-type-#{row.key}"}
                patch={messages_path(row.key, @channel, @locale)}
                class={[row.sub? && "pl-8", row.key == @type && "menu-active"]}
                aria-current={row.key == @type && "page"}
              >
                {row.label}
              </.link>
            </li>
          </ul>
        </aside>

        <div class="flex-1 min-w-0 flex flex-col gap-4">
          <div class="flex flex-wrap items-center gap-3">
            <h2 class="text-lg font-semibold">{type_label(@types, @type)}</h2>
            <div role="tablist" class="tabs tabs-box tabs-sm">
              <.link
                :for={channel <- Messages.channels()}
                role="tab"
                id={"notification-messages-channel-#{channel}"}
                patch={messages_path(@type, channel, @locale)}
                class={["tab", channel == @channel && "tab-active"]}
                aria-selected={to_string(channel == @channel)}
              >
                {channel_label(channel)}
              </.link>
            </div>
            <form id="notification-messages-lang" phx-change="select" class="ml-auto">
              <select name="lang" class="select select-sm" aria-label={gettext("Language")}>
                <option :for={{code, label} <- @locales} value={code} selected={code == @locale}>
                  {label}{if code in @edited, do: " ✎"}
                </option>
              </select>
            </form>
          </div>

          <p class="text-sm text-base-content/70">
            <%= if @edited == [] do %>
              {gettext("Every language uses the default.")}
            <% else %>
              {gettext("Own wording in: %{languages}. The others use the default.",
                languages: Enum.join(@edited, ", ")
              )}
            <% end %>
            <%= if @type != Messages.all_types() do %>
              {gettext("Without its own wording, this type uses “Every notification”'s.")}
            <% end %>
          </p>

          <p
            :if={Enum.any?(@sources, fn {_part, source} -> source == :inherited end)}
            id="notification-messages-inherited"
            class="text-sm text-info"
          >
            {gettext(
              "Some of this is inherited, not this type's own. Leave it as it is to keep inheriting; what you change here becomes this type's own."
            )}
          </p>

          <div :if={@drifted?} id="notification-messages-drift" class="alert alert-warning text-sm">
            <span>
              {gettext(
                "The default changed since this wording was saved. Compare it with the default below, then save again or reset."
              )}
            </span>
          </div>

          <div :if={@notice} id="notification-messages-notice" class="alert alert-error text-sm">
            <span>{@notice}</span>
          </div>

          <form
            id="notification-messages-push"
            phx-submit="push_settings"
            class="card bg-base-100 shadow"
          >
            <div class="card-body gap-2 py-4">
              <h3 class="font-medium">{gettext("Browser push notifications")}</h3>
              <label class="label cursor-pointer justify-start gap-2">
                <input type="hidden" name="push[enabled]" value="false" />
                <input
                  type="checkbox"
                  name="push[enabled]"
                  value="true"
                  checked={@push.enabled}
                  class="toggle toggle-sm"
                />
                <span class="label-text">{gettext("People can turn on notifications in their browser")}</span>
              </label>
              <label class="label cursor-pointer justify-start gap-2">
                <input type="hidden" name="push[show_line]" value="false" />
                <input
                  type="checkbox"
                  name="push[show_line]"
                  value="true"
                  checked={@push.show_line}
                  class="toggle toggle-sm"
                />
                <span class="label-text">
                  {gettext(
                    "Show what happened on a locked screen (otherwise only “New notification” or “3 notifications pending”)"
                  )}
                </span>
              </label>
              <label class="flex items-center gap-2 text-sm">
                <span>{gettext("Group notifications that arrive within")}</span>
                <input
                  type="number"
                  name="push[group_seconds]"
                  value={@push.group_seconds}
                  min="5"
                  max="600"
                  class="input input-sm w-20"
                />
                <span>{gettext("seconds into one")}</span>
              </label>
              <div>
                <button type="submit" class="btn btn-sm">{gettext("Save")}</button>
              </div>
            </div>
          </form>

          <div class="grid gap-4 xl:grid-cols-2">
            <form
              id="notification-messages-form"
              phx-change="change"
              phx-submit="save"
              class="card bg-base-100 shadow"
            >
              <div class="card-body gap-3">
                <input type="hidden" name="version" value={(@entry && @entry["version"]) || 0} />
                <%= for part <- Messages.parts(@channel) do %>
                  <label class="form-control w-full" for={"notification-messages-#{part}"}>
                    <span class="label-text font-medium">{part_label(part)}</span>
                    <%= if part == "subject" do %>
                      <input
                        id={"notification-messages-#{part}"}
                        type="text"
                        name={"message[#{part}]"}
                        value={@fields[part]}
                        maxlength="200"
                        class="input input-sm w-full"
                      />
                    <% else %>
                      <textarea
                        id={"notification-messages-#{part}"}
                        name={"message[#{part}]"}
                        rows="10"
                        class="textarea textarea-sm w-full font-mono"
                      >{@fields[part]}</textarea>
                    <% end %>
                  </label>
                  <details :if={@drifted? and is_binary(@defaults[part])} class="text-xs">
                    <summary class="cursor-pointer">{gettext("The default now")}</summary>
                    <pre class="whitespace-pre-wrap bg-base-200 rounded p-2 mt-1">{@defaults[part]}</pre>
                  </details>
                <% end %>

                <div class="text-xs text-base-content/70">
                  <p class="font-medium mb-1">{gettext("Variables")}</p>
                  <ul id="notification-messages-variables" class="grid gap-0.5">
                    <li :for={name <- Messages.variables(@channel)}>
                      <code>{"{{#{name}}}"}</code> — {variable_help(name)}
                    </li>
                  </ul>
                  <p class="mt-2">
                    <%= if @channel == "email" do %>
                      {gettext(
                        "Values are shown as written, never as Markdown. The site's logo and colours, the button and the setting line's link stay as they are."
                      )}
                    <% else %>
                      {gettext("Plain text. The “Open” button under the message stays as it is.")}
                    <% end %>
                  </p>
                </div>

                <div class="card-actions justify-between">
                  <button
                    :if={@entry}
                    id="notification-messages-reset"
                    type="button"
                    phx-click="reset"
                    data-confirm={gettext("Delete this wording and use the default again?")}
                    class="btn btn-ghost btn-sm"
                  >
                    {gettext("Reset to default")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm ml-auto">
                    {gettext("Save")}
                  </button>
                </div>
              </div>
            </form>

            <section class="card bg-base-100 shadow" aria-label={gettext("Preview")}>
              <div class="card-body gap-2">
                <h3 class="font-medium">{gettext("Preview, with sample values")}</h3>
                <%= cond do %>
                  <% is_nil(@preview) -> %>
                    <p class="text-sm text-base-content/60">{gettext("No preview.")}</p>
                  <% @channel == "email" -> %>
                    <p id="notification-messages-preview-subject" class="text-sm">
                      <span class="text-base-content/60">{gettext("Subject")}:</span>
                      {@preview.subject}
                    </p>
                    <%!-- An empty sandbox: the HTML runs no script and reaches
                         nothing of this page. --%>
                    <iframe
                      :if={@preview.html}
                      id="notification-messages-preview-html"
                      sandbox=""
                      referrerpolicy="no-referrer"
                      srcdoc={@preview.html}
                      title={gettext("HTML version of the email")}
                      class="w-full h-[520px] rounded-lg border border-base-300 bg-white"
                    ></iframe>
                    <details class="text-xs">
                      <summary class="cursor-pointer">{gettext("Text version")}</summary>
                      <pre id="notification-messages-preview-text" class="whitespace-pre-wrap">{@preview.text}</pre>
                    </details>
                  <% true -> %>
                    <div class="rounded-box bg-base-200 p-3 max-w-md">
                      <pre
                        id="notification-messages-preview-text"
                        class="whitespace-pre-wrap text-sm font-sans"
                      >{@preview.text}</pre>
                      <div class="mt-2 btn btn-sm btn-outline w-full pointer-events-none">
                        {@preview.button}
                      </div>
                    </div>
                <% end %>
              </div>
            </section>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
