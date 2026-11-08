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

  The menus around them differ (the admin menu has the theme switch and the
  role badge, the other the guest links), so they stay two menus.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Icons
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]

  @doc """
  The languages a menu offers: each enabled language with its `:label` (its
  own name, without the region when it is the only dialect of its language
  enabled), `:flag`, `:base` and `:active?`. Fewer than two means there is
  nothing to switch between, and the menus show no section.
  """
  @spec languages(String.t() | nil) :: [map()]
  def languages(current_locale) do
    current_base = DialectMapper.extract_base(current_locale || "")

    enabled = if Languages.enabled?(), do: Languages.get_enabled_languages(), else: []

    languages =
      enabled
      |> Enum.filter(&is_map/1)
      |> Enum.map(&describe/1)
      |> Enum.reject(&is_nil/1)

    per_base = DialectMapper.group_dialects_by_base(languages)

    Enum.map(languages, fn language ->
      language
      |> Map.put(:label, label(language, Map.get(per_base, language.base, 0)))
      |> Map.put(:active?, language.base == current_base)
    end)
  end

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
  The language list of an account menu. Renders nothing for fewer than two
  languages.

  `switch: :event` (inside a LiveView) sends `phoenix_kit_set_locale`, which
  also saves the person's choice; `switch: :link` is a plain link, for pages
  without a socket (the sign-in screens).
  """
  attr :languages, :list, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil
  attr :switch, :atom, values: [:event, :link], default: :link
  attr :divider, :boolean, default: true

  def language_section(assigns) do
    ~H"""
    <%= if length(@languages) > 1 do %>
      <div :if={@divider} class="divider my-0"></div>

      <li class="menu-title px-4 py-1">
        <span class="text-xs">{gettext("Language")}</span>
      </li>

      <%!--
        Independently scrollable list, about five rows tall. The entries are
        styled directly (no nested daisyUI <ul class="menu">), so the parent
        menu adds no submenu indent or child padding, which would force a
        horizontal scroll. `!p-0` resets the padding the parent menu gives the
        wrapper <li>'s children.
      --%>
      <li class="p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
        <div class="!p-0 block w-full max-h-60 overflow-y-auto overflow-x-hidden !bg-transparent hover:!bg-transparent focus:!bg-transparent">
          <%= for language <- @languages do %>
            <% url =
              Routes.locale_switch_path(@current_path, language.code, current_locale: @current_locale) %>
            <button
              :if={@switch == :event}
              type="button"
              phx-click="phoenix_kit_set_locale"
              phx-value-locale={language.code}
              phx-value-url={url}
              class={[
                entry_class(language),
                "phx-click-loading:opacity-60 phx-click-loading:pointer-events-none"
              ]}
            >
              <.language_entry language={language} />
            </button>
            <a :if={@switch == :link} href={url} class={entry_class(language)}>
              <.language_entry language={language} />
            </a>
          <% end %>
        </div>
      </li>
    <% end %>
    """
  end

  attr :language, :map, required: true

  defp language_entry(assigns) do
    ~H"""
    <span class="text-lg">{@language.flag}</span>
    <span lang={@language.base} title={@language.name}>{@language.label}</span>
    <Icons.icon_check :if={@language.active?} class="w-4 h-4 ml-auto" />
    """
  end

  defp entry_class(language) do
    [
      "w-full flex items-center gap-3 rounded-lg px-4 py-2 text-sm",
      "focus:outline-none focus-visible:outline-none",
      if(language.active?,
        do:
          "bg-primary !text-primary-content hover:bg-primary hover:!text-primary-content active:!bg-primary/80",
        else:
          "!text-base-content hover:bg-base-200 hover:!text-base-content focus:!text-base-content active:!text-base-content active:!bg-base-300"
      )
    ]
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
                {account.role}
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
              <span class="badge badge-xs badge-ghost shrink-0">{account.role}</span>
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
  providers enabled in Settings. Each provider link carries `add_account=1`,
  so the OAuth callback adds the account to the session instead of replacing it.
  """
  attr :id, :string, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil

  def add_account_modal(assigns) do
    assigns =
      assign(assigns, :providers, [
        {:google, OAuthAvailability.provider_enabled?(:google)},
        {:github, OAuthAvailability.provider_enabled?(:github)},
        {:facebook, OAuthAvailability.provider_enabled?(:facebook)}
      ])

    ~H"""
    <input type="checkbox" id={@id} class="modal-toggle" />
    <div class="modal" role="dialog">
      <div class="modal-box">
        <h3 class="text-lg font-bold mb-4">{gettext("Add account")}</h3>
        <.form
          for={%{}}
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
          <div class="modal-action">
            <label for={@id} class="btn btn-outline">{gettext("Cancel")}</label>
            <button type="submit" class="btn btn-primary">{gettext("Add account")}</button>
          </div>
        </.form>

        <div :if={Enum.any?(@providers, &elem(&1, 1))} class="mt-4">
          <div class="divider text-base-content/60 text-xs">{gettext("Or add via")}</div>
          <div class="space-y-2">
            <.link
              :for={{provider, true} <- @providers}
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
