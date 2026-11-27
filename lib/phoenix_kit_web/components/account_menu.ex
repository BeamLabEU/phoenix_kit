defmodule PhoenixKitWeb.Components.AccountMenu do
  @moduledoc """
  The parts both account menus share: the admin header's
  (`PhoenixKitWeb.Components.AdminNav.admin_user_dropdown/1`) and the one on
  the user-facing pages and the sign-in screens
  (`PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1`).

    * `language_section/1` — the language list, each language under its own
      name ("Deutsch", "Français"), so a reader finds their language without
      knowing its English word.
    * `accounts_section/1` — the signed-in accounts, with switch and remove.
    * `add_account_modal/1` — the "Add account" dialog, OAuth buttons included.
    * `theme_section/1` — the "Theme" row: System, light, dark.

  The menus around them differ (the admin header has its own theme picker
  beside the menu and the role badge, the other the guest links), so they
  stay two menus.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Handoff
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Icons
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher
  alias PhoenixKitWeb.Components.Core.ThemeController
  alias PhoenixKitWeb.Components.ThemeControllerScript

  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.TurnstileWidget, only: [turnstile_widget: 1]

  @doc """
  The "Theme" row of an account menu: follow the system, or the light or the
  dark theme, every choice in view.

  The two themes are the pair "system" resolves to
  (`PhoenixKit.ThemeConfig.system_pair/0`), whatever longer list the admin
  header's picker offers: a menu row has room for a three-way choice, not for
  a catalogue. The choice is the browser's (`localStorage`), the same one every
  other theme picker of the kit reads and writes, so it is offered to a
  visitor who is not signed in too.

  Renders `PhoenixKitWeb.Components.ThemeControllerScript` with it, which a
  page needs once for the buttons to do anything; that script is idempotent,
  so a layout that already renders it loses nothing. A script that arrives in
  a LiveView patch does not run, so a host with pages that have NO menu, from
  which a visitor can live-navigate to one that has it, renders the script in
  its root layout as well.
  """
  attr :id, :string, required: true, doc: "unique on the page"

  def theme_section(assigns) do
    {light, dark} = ThemeConfig.system_pair()
    assigns = assign(assigns, :themes, ["system", light, dark])

    ~H"""
    <div class="divider my-0"></div>
    <%!-- Not an <li>: a menu item would light up as a whole on hover and
         press, and this row is three buttons of its own. --%>
    <div class="flex items-center justify-between gap-3 px-3 py-1.5" data-account-menu-theme>
      <span class="flex items-center gap-3 text-sm">
        <PhoenixKitWeb.Components.Core.Icon.icon name="hero-swatch" class="w-4 h-4" />
        <span>{gettext("Theme")}</span>
      </span>
      <ThemeController.theme_controller mode={:inline} themes={@themes} id={@id} />
    </div>
    <ThemeControllerScript.theme_controller_script />
    """
  end

  @doc """
  The languages a menu offers: each enabled language with its `:label` (its
  own name, without the region when it is the only dialect of its language
  enabled), `:flag`, `:base`, `:active?`, `:handoff` and `:page_path`. Fewer
  than two means there is nothing to switch between, and the menus show no
  section.

  `:handoff` is `nil`, or says the page should hand the visitor over to the
  language rather than switch to it: it has a domain of its own, which is not
  the one the page is served on (`current_host`, a host name without port; see
  `PhoenixKit.Handoff.hand_over_languages/2` for the two kinds, `:host_language`
  and `:dialect`). With no `current_host` it is `nil` for every language, and
  nothing is asked of the host resolver.

  `language_urls` is the page's own URL per language, for a page whose address
  differs per language (a post with a translated slug, a product): what
  publishing hands a host as `phoenix_kit_publishing_translations`, or a plain
  `%{code => url}` (`LanguageSwitcher.translation_url/2` reads it: the exact
  code first, then the bare base language, then any dialect of it). A language
  with a usable URL there gets it as `:page_path`, a local path with its query
  (a fragment is dropped), and the menu leads there instead of to the current
  path rewritten for that language. A URL the page gives is that language's
  address and is not rewritten (the kit's prefix is not added to it): on this
  domain it is used as it is; for a handoff entry it is the destination on the
  language's own domain, from which only the language's own leading locale
  segment goes (`Routes.domain_page_path/2`), and a dialect that shares the
  domain keeps its URL whole.

  Only two kinds of URL are used: a local path, or an absolute `http(s)` URL
  whose host is the one the entry is for (the page's `current_host`, so an
  absolute URL is ignored without one; or the language's own host for a handoff
  entry), reduced to its path and query (no path is `/`). Anything else
  (another host, `//host`, `javascript:`, no list, no entry) is ignored, as if
  the language had no entry, so the attr never leads off the site.
  """
  @spec languages(String.t() | nil, String.t() | nil, term()) :: [map()]
  def languages(current_locale, current_host \\ nil, language_urls \\ nil) do
    enabled = if Languages.enabled?(), do: Languages.get_enabled_languages(), else: []

    languages =
      enabled
      |> Enum.filter(&is_map/1)
      |> Enum.map(&describe/1)
      |> Enum.reject(&is_nil/1)

    per_base = DialectMapper.group_dialects_by_base(languages)

    locale = current_locale || Gettext.get_locale(PhoenixKitWeb.Gettext)
    base = DialectMapper.extract_base(locale)

    active =
      Enum.find(languages, &(&1.code == locale)) ||
        Enum.find(languages, &(&1.code == DialectMapper.base_to_dialect(base))) ||
        Enum.find(languages, &(&1.base == base))

    handoff = Handoff.hand_over_languages(current_host, Enum.map(languages, & &1.code))

    Enum.map(languages, fn language ->
      target = Map.get(handoff, language.code)

      language
      |> Map.put(:label, label(language, Map.get(per_base, language.base, 0)))
      |> Map.put(:active?, language == active)
      |> Map.put(:handoff, target && target.kind)
      |> Map.put(
        :page_path,
        page_path(language_urls, language.code, target, current_host)
      )
    end)
  end

  # The page's own URL in a language, reduced to a local path, or nil: no list, no entry, or a URL
  # that is not one of this site's (see `languages/3`). A URL the page gives is the address of
  # that language, so on the page's own domain it is used as it is, and through the handoff only
  # the language's own leading locale segment goes (that domain carries the language): a dialect
  # that shares the domain keeps its URL whole, an absolute URL of the domain is already its
  # address. The result is checked once more, whatever was done to it.
  defp page_path(language_urls, code, target, current_host) do
    with url when is_binary(url) <- LanguageSwitcher.translation_url(language_urls, code),
         path when is_binary(path) <-
           destination(reduce_url(url, host_of(target, current_host)), target, code) do
      Handoff.valid_to(path)
    end
  end

  defp host_of(nil, current_host), do: current_host
  defp host_of(%{host: host}, _current_host), do: host

  defp destination(nil, _target, _code), do: nil
  defp destination({_, path}, nil, _code), do: path
  defp destination({:absolute, path}, _target, _code), do: path
  defp destination({:relative, path}, %{kind: :dialect}, _code), do: path

  defp destination({:relative, path}, %{kind: _host_language}, code),
    do: Routes.domain_page_path(path, code)

  # `{:relative | :absolute, "/path?query"}` for a local path, or an absolute http(s) URL of
  # `host` (host names compared without port or case); nil for anything else. The result is
  # always a local path (`PhoenixKit.Handoff.valid_to/1`): the host of an absolute URL is
  # checked and dropped, never followed.
  defp reduce_url(url, host) do
    case URI.parse(url) do
      %URI{scheme: nil, host: nil} = uri ->
        tag(:relative, uri)

      %URI{scheme: scheme, host: uri_host} = uri when scheme in ["http", "https"] ->
        if same_host?(uri_host, host), do: tag(:absolute, uri)

      _ ->
        nil
    end
  end

  # An absolute URL with no path is the host's home page.
  defp tag(:absolute, %URI{path: path} = uri) when path in [nil, ""],
    do: tag(:absolute, %{uri | path: "/"})

  defp tag(kind, %URI{path: path, query: query}) do
    case Handoff.valid_to(to_string(path) <> if(query, do: "?" <> query, else: "")) do
      nil -> nil
      local -> {kind, local}
    end
  end

  defp same_host?(uri_host, host) when is_binary(uri_host) and is_binary(host),
    do: String.downcase(uri_host) == host |> Handoff.host_name() |> String.downcase()

  defp same_host?(_uri_host, _host), do: false

  # The locale segment a destination on a language's domain keeps: none, unless the domain serves
  # another language first, and then the language's own.
  defp destination_segment(:dialect, code), do: code
  defp destination_segment(_kind, _code), do: :none

  defp describe(language) do
    code = Map.get(language, :code)

    if is_binary(code) do
      predefined = Languages.get_predefined_language(code) || %{}

      %{
        code: code,
        base: DialectMapper.extract_base(code),
        name: Map.get(predefined, :name) || Map.get(language, :name) || String.upcase(code),
        native: Map.get(predefined, :native),
        flag: Map.get(predefined, :flag) || "🌐"
      }
    end
  end

  # The language's own name. With one dialect of a language enabled the region
  # adds nothing ("Deutsch", not "Deutsch (Deutschland)"); with two it tells
  # them apart. A language with no known native name keeps its English one.
  defp label(%{native: native} = language, dialects) when is_binary(native) and native != "" do
    if dialects > 1, do: native, else: bare(native, language.name)
  end

  defp label(language, dialects) do
    if dialects > 1,
      do: language.name,
      else: LanguageSwitcher.extract_base_language_name(language.name)
  end

  defp bare(native, name) do
    case LanguageSwitcher.extract_base_language_name(native) do
      "" -> LanguageSwitcher.extract_base_language_name(name)
      short -> short
    end
  end

  @doc """
  The current language of an account menu, with the other enabled languages in
  a submenu. Renders nothing for fewer than two languages.

  `switch: :event` (inside a LiveView) sends `phoenix_kit_set_locale`, which
  also saves the person's choice; `switch: :link` is a plain link, for pages
  without a socket (the sign-in screens).

  A language with a `:handoff` (see `languages/2`) leads to
  `PhoenixKit.Handoff.start_path/2` instead of the language switch, so the
  visitor's sign-in and cart travel to the language's own domain: the `<a>` of
  the link mode gets `rel="nofollow"`, and the event mode keeps its event
  (the person's choice is still saved), whose handler leaves the page for that
  url. The destination is the current path as the language's own domain serves
  it: with no locale segment, unless another enabled language is listed first
  for that domain (a sibling dialect, say), and then the language's own segment
  stays.
  """
  attr :languages, :list, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil
  attr :switch, :atom, values: [:event, :link], default: :link
  attr :divider, :boolean, default: true

  def language_section(assigns) do
    {current, alternatives} = Enum.split_with(assigns.languages, & &1.active?)

    assigns =
      assigns
      |> assign(:current, List.first(current))
      |> assign(:alternatives, alternatives)

    ~H"""
    <%= if length(@languages) > 1 do %>
      <div :if={@divider} class="divider my-0"></div>
      <li class="w-full">
        <pk-session-languages class="w-full !block !p-0 !bg-transparent">
          <details class="col-span-full w-full">
            <summary class="flex cursor-pointer list-none items-center gap-3 rounded-lg px-4 py-2 hover:bg-base-200 focus-visible:outline">
              <span class={if @current, do: "sr-only"}>{gettext("Language")}</span>
              <.language_entry :if={@current} language={@current} />
              <span class="ms-auto" aria-hidden="true">▾</span>
            </summary>
            <div class="rounded-box border border-base-300 bg-base-100 text-base-content shadow-lg p-1 max-h-60 overflow-y-auto">
              <%= for language <- @alternatives do %>
                <% url = language_url(language, @current_path, @current_locale) %>
                <button
                  :if={@switch == :event}
                  type="button"
                  phx-click="phoenix_kit_set_locale"
                  phx-value-locale={language.code}
                  phx-value-url={url}
                  class="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-start hover:bg-base-200 focus-visible:outline phx-click-loading:opacity-60"
                >
                  <.language_entry language={language} />
                </button>
                <a
                  :if={@switch == :link}
                  href={url}
                  rel={language[:handoff] && "nofollow"}
                  class="flex items-center gap-3 rounded-lg px-3 py-2 hover:bg-base-200 focus-visible:outline"
                >
                  <.language_entry language={language} />
                </a>
              <% end %>
            </div>
          </details>
        </pk-session-languages>
      </li>
    <% end %>
    """
  end

  # Where an entry of the list leads: the language switch, or the handoff start when the
  # language has a domain of its own. The destination there is the path as that domain serves
  # it, so the locale segment goes (the domain carries the language) unless another enabled
  # language is listed first for that domain, and then the language's own segment stays.
  defp language_url(language, current_path, current_locale) do
    case language[:handoff] do
      nil ->
        language[:page_path] ||
          Routes.locale_switch_path(current_path, language.code, current_locale: current_locale)

      kind ->
        Handoff.start_path(
          language.code,
          language[:page_path] ||
            Routes.locale_switch_path(current_path, destination_segment(kind, language.code),
              current_locale: current_locale
            )
        )
    end
  end

  attr :language, :map, required: true

  defp language_entry(assigns) do
    ~H"""
    <span class="text-lg" aria-hidden="true">{@language.flag}</span>
    <span lang={@language.code} title={@language.name}>{@language.label}</span>
    """
  end

  @doc """
  The signed-in accounts of a multi-account session: switch to one, remove
  one, and "Add account", which opens `add_account_modal/1` (`modal_id`).
  """
  attr :scope, :any, required: true
  attr :accounts, :list, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil
  attr :modal_id, :string, required: true

  def accounts_section(assigns) do
    assigns = assign(assigns, :removable?, any_removable_account?(assigns.accounts))

    ~H"""
    <div class="divider my-0"></div>

    <li class="menu-title px-4 py-1">
      <span class="text-xs">{gettext("Accounts")}</span>
    </li>

    <%!--
      Account rows. The wrapper div is the only `li > *`, so it carries the
      `!p-0` / `!bg-transparent` reset for the padding and hover colour
      daisyUI's `menu` puts on a menu item's direct child; every bit of spacing
      then lives on the inner row, which is structurally identical in both
      branches. That keeps the active row's email flush with the others.

      `flex-nowrap` on the li and `w-full` on the row: daisyUI's menu `li` is a
      WRAPPING column flex, whose line is as wide as its widest item's content,
      so a long email would stretch the row past the menu's edge.
    --%>
    <li :for={account <- @accounts} class="p-0 min-w-0 flex-nowrap">
      <div class="!p-0 flex w-full items-center gap-1 min-w-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
        <%= if account.active? do %>
          <div class="flex-1 min-w-0">
            <div class="flex w-full min-w-0 items-center gap-2 rounded-lg bg-primary px-4 py-2 text-primary-content">
              <span class="flex-1 min-w-0 truncate" title={account.email}>
                {account.email}
              </span>
              <span class="badge badge-xs border-0 bg-primary-content/20 text-primary-content shrink-0">
                {PhoenixKit.Users.Roles.display_name(%{name: account.role})}
              </span>
              <Icons.icon_check class="w-4 h-4 shrink-0" />
            </div>
          </div>
        <% else %>
          <.form
            for={%{}}
            action={localized(@current_locale, "/users/session/active")}
            method="put"
            class="flex-1 min-w-0"
          >
            <input type="hidden" name="ref" value={account.ref} />
            <input type="hidden" name="return_to" value={@current_path} />
            <%!--
              `text-start` is load-bearing. A <button> inherits the UA
              `text-align: center`, and the email span is `flex-1`, so a short
              email would centre itself and drift right of the active row's.
            --%>
            <button
              type="submit"
              class="flex w-full min-w-0 items-center gap-2 rounded-lg px-4 py-2 text-start hover:bg-base-200"
            >
              <span class="flex-1 min-w-0 truncate" title={account.email}>
                {account.email}
              </span>
              <span class="badge badge-xs badge-ghost shrink-0">{PhoenixKit.Users.Roles.display_name(
                %{name: account.role}
              )}</span>
              <%!-- Stands in for the active row's check so the role badges share a right edge. --%>
              <span class="w-4 shrink-0" aria-hidden="true"></span>
            </button>
          </.form>
        <% end %>

        <%!--
          Fixed-width trailing slot, on every row as soon as one account is
          removable, so the email column keeps one width down the list. Empty
          for the active and root rows.
        --%>
        <div :if={@removable?} class="w-6 shrink-0 flex items-center justify-center">
          <.form
            :if={not account.active? and not account.root?}
            for={%{}}
            action={localized(@current_locale, "/users/session/accounts/#{account.ref}")}
            method="delete"
          >
            <input type="hidden" name="return_to" value={@current_path} />
            <button
              type="submit"
              class="btn btn-ghost btn-xs btn-square text-error"
              title={gettext("Remove")}
              aria-label={gettext("Remove %{account}", account: account.email)}
            >
              <Icons.icon_x_thin class="w-3 h-3" />
            </button>
          </.form>
        </div>
      </div>
    </li>

    <li :if={is_nil(Scope.acting_user_uuid(@scope))} class="p-0">
      <label
        for={@modal_id}
        class="!p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent cursor-pointer"
      >
        <span class="flex w-full items-center gap-3 rounded-lg px-4 py-2 hover:bg-base-200">
          <Icons.icon_user_add class="w-4 h-4 shrink-0" />
          <span>{gettext("Add account")}</span>
        </span>
      </label>
    </li>
    """
  end

  # True when at least one account row can show its remove button.
  defp any_removable_account?(accounts) do
    Enum.any?(accounts, &(not &1.active? and not &1.root?))
  end

  @doc """
  The "Add account" dialog: email or username and password, then the OAuth
  providers that have credentials (`OAuthAvailability.configured_providers_cached/0`).
  A switch with nothing behind it is not offered. Each provider link carries
  `add_account=1`, so the OAuth callback adds the account to the session
  instead of replacing it.
  """
  attr :id, :string, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil

  def add_account_modal(assigns) do
    assigns = assign(assigns, :providers, OAuthAvailability.configured_providers_cached())

    ~H"""
    <input type="checkbox" id={@id} class="modal-toggle" />
    <div class="modal" role="dialog">
      <div class="modal-box">
        <h3 class="text-lg font-bold mb-4">{gettext("Add account")}</h3>
        <.form
          for={%{}}
          id={@id <> "-form"}
          action={localized(@current_locale, "/users/session/accounts")}
          method="post"
          class="space-y-4"
        >
          <input type="hidden" name="return_to" value={@current_path} />
          <div class="fieldset">
            <label class="label">
              <span class="fieldset-legend">{gettext("Email or username")}</span>
            </label>
            <input name="user[email_or_username]" type="text" required class="input w-full" />
          </div>
          <div class="fieldset">
            <label class="label"><span class="fieldset-legend">{gettext("Password")}</span></label>
            <.input
              id={@id <> "-password"}
              name="user[password]"
              type="password"
              value=""
              required
              password_toggle
            />
          </div>
          <.turnstile_widget
            auth_form="password_login"
            id={@id <> "-turnstile"}
            class="mt-2"
          />
          <div class="modal-action">
            <label for={@id} class="btn btn-outline">{gettext("Cancel")}</label>
            <button type="submit" class="btn btn-primary">{gettext("Add account")}</button>
          </div>
        </.form>

        <div :if={@providers != []} class="mt-4">
          <div class="divider text-base-content/60 text-xs">{gettext("Or add via")}</div>
          <div class="space-y-2">
            <.link
              :for={provider <- @providers}
              href={
                Routes.path("/users/auth/#{provider}", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <.provider_icon provider={provider} />
              <span>{provider_label(provider)}</span>
            </.link>
          </div>
        </div>
      </div>
      <label class="modal-backdrop" for={@id}>{gettext("Close")}</label>
    </div>
    """
  end

  attr :provider, :atom, required: true

  defp provider_icon(%{provider: :google} = assigns),
    do: ~H'<Icons.icon_google class="w-5 h-5" />'

  defp provider_icon(%{provider: :github} = assigns),
    do: ~H'<Icons.icon_github class="w-5 h-5" />'

  defp provider_icon(%{provider: :facebook} = assigns),
    do: ~H'<Icons.icon_facebook class="w-5 h-5" />'

  defp provider_label(:google), do: gettext("Add Google account")
  defp provider_label(:github), do: gettext("Add GitHub account")
  defp provider_label(:facebook), do: gettext("Add Facebook account")

  defp localized(current_locale, path),
    do: Routes.locale_aware_path(%{current_locale: current_locale}, path)
end
