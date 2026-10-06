defmodule PhoenixKitWeb.Components.ProfileSettingsTabs do
  @moduledoc """
  The tabs of the signed-in user's own settings, `/profile/settings/<tab>`.

  One URL per tab, and a tab is offered only when it has something to show
  for this user:

    * `account` — who you are: avatar and name, custom fields, email, and
      the start page
    * `security` — password and connected sign-in accounts
    * `sessions` — signed-in devices and recent sign-in attempts
    * `notifications` — which notifications you get (when any types exist)
    * `integrations` — your own service connections, for holders of the
      opt-in `integrations` permission. Its own LiveView at
      `/profile/settings/integrations`.
    * `media` — how media behaves for you: the annotation-tools section
      (open-in-editor switch, tool reset), and — while user libraries are
      on and you hold the `"storage"` permission — your storage libraries
      and their members (`PhoenixKitWeb.Live.Components.LibrarySettings`;
      the end-user surface for those is `phoenix_kit_photos`). The tab is
      offered to everyone, because the annotation section applies to
      anyone who can open the media viewer; the library card inside keeps
      its own gate.

  `/profile/settings` opens the first tab. Every section of
  `PhoenixKitWeb.Live.Components.UserSettings.default_sections/0` is on
  exactly one tab (a section on none would be one nobody can reach).

  ## Hiding sections

  An admin can hide sections a site does not use (Settings → Users →
  Profile page). What is stored is the list of HIDDEN sections, in the
  `user_settings_hidden_sections` setting — so a section added in a later
  release shows up on existing sites instead of staying invisible. A tab
  whose sections are all hidden is not offered. `:identity` (name and
  avatar) cannot be hidden. `:google_email` is the Google address field
  inside the identity form, hideable on its own.
  """
  use PhoenixKitWeb, :html

  require Logger

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Notifications.Types, as: NotificationTypes
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  # The `UserSettings` sections each tab renders, in page order.
  @sections %{
    "account" => [:identity, :custom_fields, :email, :start_page],
    "security" => [:password, :oauth],
    "sessions" => [:sessions],
    "notifications" => [:notifications],
    "media" => [:etcher]
  }

  @order ~w(account security sessions notifications integrations media)

  @hidden_key "user_settings_hidden_sections"

  # What an admin may hide, in the order the settings page lists them.
  @hideable [
    :google_email,
    :custom_fields,
    :email,
    :start_page,
    :etcher,
    :password,
    :oauth,
    :sessions,
    :notifications
  ]

  @doc "The sections (and the `:google_email` field) an admin may hide."
  @spec hideable_sections() :: [atom()]
  def hideable_sections, do: @hideable

  @doc "The sections an admin has hidden. Unknown names are ignored."
  @spec hidden_sections() :: [atom()]
  def hidden_sections do
    @hidden_key
    |> PhoenixKit.Settings.get_json_setting_cached(%{"hidden" => []})
    |> stored_hidden()
  rescue
    # Fails open (every section shows) — but on the record. An unreachable DB
    # raises on an unowned checkout but exits on a dead pool, so both are caught.
    error ->
      Logger.warning(
        "[ProfileSettingsTabs] hidden sections unreadable: #{Exception.message(error)}"
      )

      []
  catch
    :exit, reason ->
      Logger.warning("[ProfileSettingsTabs] hidden sections unreadable: #{inspect(reason)}")

      []
  end

  defp stored_hidden(%{"hidden" => names}) when is_list(names),
    do: Enum.filter(@hideable, &(Atom.to_string(&1) in names))

  defp stored_hidden(_value), do: []

  @doc """
  Hides or shows `section` for every user. `section` must be hideable.
  `opts` reach the setting write (`actor_uuid:`, `source:`), so the change
  is attributed like any other settings save.
  """
  @spec set_section_hidden(atom(), boolean(), keyword()) :: :ok | {:error, term()}
  #
  # A read-modify-write of one list, so it runs under a transaction lock on
  # the key and reads the stored value, not the cache: two admins toggling
  # different sections at once must both land.
  def set_section_hidden(section, hidden?, opts \\ [])

  def set_section_hidden(section, hidden?, opts) when section in @hideable do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@hidden_key])

      names =
        @hidden_key
        |> PhoenixKit.Settings.get_json_setting(%{"hidden" => []})
        |> stored_hidden()
        |> then(&if(hidden?, do: Enum.uniq(&1 ++ [section]), else: List.delete(&1, section)))
        |> Enum.map(&Atom.to_string/1)

      case PhoenixKit.Settings.update_json_setting(@hidden_key, %{"hidden" => names}, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} ->
        # The write invalidated the cache before the transaction committed,
        # so a reader in between could have cached the OLD list under the
        # new generation. Invalidate again now that the new row is visible.
        PhoenixKit.Cache.invalidate(:settings, @hidden_key)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_section_hidden(_section, _hidden?, _opts), do: {:error, :not_hideable}

  @doc "Whether the Google address field shows in the identity form."
  @spec google_email_shown?() :: boolean()
  def google_email_shown?, do: :google_email not in hidden_sections()

  @doc "The tab `/profile/settings` opens on."
  @spec default_tab() :: String.t()
  def default_tab, do: "account"

  @doc """
  The `UserSettings` sections a tab rendered by `ProfileSettings` shows, or
  nil for a tab that is not one of them (integrations has a page of its own).
  """
  @spec sections(String.t()) :: [atom()] | nil
  def sections(tab) do
    case Map.get(@sections, tab) do
      nil -> nil
      sections -> sections -- hidden_sections()
    end
  end

  @doc "Whether `ProfileSettings` renders the tab itself (every tab but integrations)."
  @spec rendered_here?(String.t()) :: boolean()
  def rendered_here?(tab), do: Map.has_key?(@sections, tab)

  @doc "Every section some tab shows."
  @spec all_sections() :: [atom()]
  def all_sections, do: @sections |> Map.values() |> List.flatten()

  @doc "The ids of the tabs `scope` is offered, in order."
  @spec tab_ids(Scope.t() | nil) :: [String.t()]
  def tab_ids(scope), do: Enum.filter(@order, &visible?(&1, scope))

  defp visible?("notifications", _scope),
    do: NotificationTypes.list() != [] and sections("notifications") != []

  defp visible?("integrations", scope),
    do: not is_nil(scope) and Scope.has_module_access?(scope, "integrations")

  # "media" has no permission gate of its own: the annotation-tools
  # section on it applies to anyone who can open the media viewer, so the
  # tab shows for everyone while that section does — the libraries card
  # inside keeps its own `Libraries.may_use_libraries?/1` check. With the
  # annotation section hidden by an admin, the tab is only worth offering
  # to someone the libraries card will render for.
  defp visible?("media", scope),
    do: sections("media") != [] or Libraries.may_use_libraries?(scope)

  # A tab of hidden sections only has nothing to show.
  defp visible?(tab, _scope) when is_map_key(@sections, tab), do: sections(tab) != []
  defp visible?(_tab, _scope), do: true

  @doc "The path of a tab."
  @spec path(String.t()) :: String.t()
  def path(tab), do: Routes.path("/profile/settings/#{tab}")

  @doc """
  The tab strip. `active` is the tab being shown; `scope` decides which tabs
  are offered. Tabs rendered by the same LiveView patch; the integrations
  tab, a LiveView of its own, navigates.
  """
  attr :active, :string, required: true
  attr :scope, :any, required: true

  def profile_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, Enum.map(tab_ids(assigns.scope), &tab(&1, assigns.active)))

    ~H"""
    <.nav_tabs active_tab={@active} tabs={@tabs} variant={:border} class="mb-6" />
    """
  end

  # From inside `ProfileSettings`, the tabs it renders itself patch and the
  # integrations tab navigates; from the integrations page every tab
  # navigates back into `ProfileSettings`.
  defp tab(id, active) do
    link =
      if id != "integrations" and rendered_here?(active),
        do: [patch: path(id)],
        else: [navigate: path(id)]

    Map.merge(%{id: id, label: tab_label(id), icon: tab_icon(id)}, Map.new(link))
  end

  defp tab_label("account"), do: gettext("Account")
  defp tab_label("security"), do: gettext("Security")
  defp tab_label("sessions"), do: gettext("Sessions")
  defp tab_label("notifications"), do: gettext("Notifications")
  defp tab_label("integrations"), do: gettext("Integrations")
  defp tab_label("media"), do: gettext("Media")

  defp tab_icon("account"), do: "hero-user-circle"
  defp tab_icon("security"), do: "hero-lock-closed"
  defp tab_icon("sessions"), do: "hero-computer-desktop"
  defp tab_icon("notifications"), do: "hero-bell"
  defp tab_icon("integrations"), do: "hero-link"
  defp tab_icon("media"), do: "hero-rectangle-stack"
end
