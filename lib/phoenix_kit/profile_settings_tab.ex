defmodule PhoenixKit.ProfileSettingsTab do
  @moduledoc """
  A tab a host application or a module adds to the signed-in user's settings
  strip, `/profile/settings/<id>` (`PhoenixKitWeb.Components.ProfileSettingsTabs`).

  The tab is a link to a page of its own, like core's Integrations tab: every
  tab of the strip navigates to it, and it navigates back. The page renders
  the strip itself so it looks like the other tabs:

      <PhoenixKitWeb.Components.LayoutWrapper.app_layout
        socket={@socket}
        flash={@flash}
        phoenix_kit_current_scope={@phoenix_kit_current_scope}
        page_title={gettext("My tab")}
        current_path={PhoenixKitWeb.Components.ProfileSettingsTabs.path("my-tab")}
      >
        <div class="max-w-7xl mx-auto px-4 py-6 sm:px-6 lg:px-8">
          <PhoenixKitWeb.Components.ProfileSettingsTabs.profile_tabs
            active="my-tab"
            scope={@phoenix_kit_current_scope}
          />
          ...
        </div>
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>

  ## Declaring tabs

  A host lists them in config:

      config :phoenix_kit, :profile_settings_tabs, [
        %{
          id: "my-tab",
          label: {MyAppWeb.ProfileTabs, :my_tab_label, []},
          icon: "hero-puzzle-piece",
          after: "security",
          visible: {MyApp.MyFeature, :available?},
          live_view: MyAppWeb.MyTabLive
        }
      ]

  Use the tuple forms in config: a release cannot carry a function in its
  config. A module returns the same maps from `c:PhoenixKit.Module.profile_settings_tabs/0`
  (functions are fine there);
  its tabs are offered only while the module is enabled. Host tabs come
  first; when two declare one id, the first wins and the other is dropped
  with a warning.

  ## Fields

    * `:id` (required) — the URL segment, `/profile/settings/<id>`: lowercase
      letters, digits, `-` and `_`, starting with a letter or digit. Not one of
      core's tab ids or `confirm-email` (`reserved_ids/0`).
    * `:label` (required) — a string, a `{module, function, args}` or a
      zero-arity function. The last two are called on every render, after
      the kit has set the request's Gettext locale, so they can return the
      host's own `gettext("My tab")` — a plain string is shown as is.
    * `:icon` — a heroicon name (`"hero-puzzle-piece"`), default
      `"hero-squares-2x2"`.
    * `:after` — the id of the tab this one follows (a core tab or another
      registered one). Absent, or naming a tab that does not exist, puts it
      at the end. Tabs after the same one keep their declared order.
    * `:permission` — a permission key the user must hold
      (`PhoenixKit.Users.Auth.Scope.can?/2`, including its base permission
      and live feature-enablement checks). It must be a key the permission
      system knows — a module's, a core section's, or a host key registered
      with `PhoenixKit.Users.Permissions.register_custom_key/2`; an unknown
      key reads as a disabled feature and hides the tab.
    * `:visible` — `{module, function}` or a one-argument function, called
      with the scope (`nil` for nobody signed in); the tab is offered when it
      returns `true`. One that raises hides the tab (with one warning). With
      `:permission` too, both must pass.
    * `:live_view` — the page: a LiveView module or `{module, action}`
      (action `:index` by default). Core then declares
      `live "/profile/settings/<id>"` in its authenticated `live_session`, in
      both the locale-prefixed and the plain URL shapes, before its own
      `/profile/settings/:tab`. Without it the host declares the route ITSELF,
      before `phoenix_kit_routes()` (and in both shapes); a tab whose page is
      missing lands on `ProfileSettings`, which redirects it to the first tab.

  The tab decides what the strip offers, not who may open the page: the
  page checks access in its own `mount/3`, as any page does.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope

  @type label :: String.t() | {module(), atom(), list()} | (-> String.t())
  @type visible :: {module(), atom()} | (term() -> boolean()) | nil

  @type t :: %__MODULE__{
          id: String.t(),
          label: label(),
          icon: String.t(),
          after: String.t() | nil,
          permission: String.t() | nil,
          visible: visible(),
          live_view: {module(), atom()} | nil,
          module: module() | nil
        }

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    :after,
    :permission,
    :visible,
    :live_view,
    :module,
    icon: "hero-squares-2x2"
  ]

  @fields ~w(id label icon after permission visible live_view)a

  # Core's own tabs, plus the confirmation landing page under the same path.
  @reserved_ids ~w(account managers security sessions notifications integrations api-keys media confirm-email)

  @id_format ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @doc "The ids a registered tab cannot take."
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @doc """
  The registered tabs: the host's (`config :phoenix_kit, :profile_settings_tabs`)
  followed by those of the enabled modules. Invalid and duplicate entries are
  dropped, each with one warning.
  """
  @spec all() :: [t()]
  def all do
    (config_tabs() ++ PhoenixKit.ModuleRegistry.all_profile_settings_tabs())
    |> drop_duplicates()
  end

  @doc """
  The tabs whose page core routes, for the router macros: the host's and
  those of every discovered module, enabled or not (routes are compiled;
  the strip asks `enabled?/0` at render time). `modules` are the modules to
  ask, already compiled.
  """
  @spec routed([module()]) :: [t()]
  def routed(modules) do
    module_tabs =
      Enum.flat_map(modules, fn mod ->
        if function_exported?(mod, :profile_settings_tabs, 0),
          do: from_module(mod),
          else: []
      end)

    (config_tabs() ++ module_tabs)
    |> drop_duplicates()
    |> Enum.filter(& &1.live_view)
  end

  @doc "The host's raw config entries, as the router compares them for recompiles."
  @spec config_entries() :: term()
  def config_entries, do: Application.get_env(:phoenix_kit, :profile_settings_tabs, [])

  @doc """
  The tabs `mod.profile_settings_tabs/0` declares, normalised. A callback that
  raises contributes nothing (one warning).
  """
  @spec from_module(module()) :: [t()]
  def from_module(mod) do
    mod.profile_settings_tabs()
    |> List.wrap()
    |> normalize_all(mod, "#{inspect(mod)}.profile_settings_tabs/0")
  rescue
    error ->
      warn_once(
        {:failed, mod},
        "#{inspect(mod)}.profile_settings_tabs/0 raised #{inspect(error.__struct__)}"
      )

      []
  catch
    kind, _reason ->
      warn_once({:failed, mod}, "#{inspect(mod)}.profile_settings_tabs/0 failed (#{kind})")
      []
  end

  defp config_tabs do
    config_entries()
    |> List.wrap()
    |> normalize_all(nil, "config :phoenix_kit, :profile_settings_tabs")
  end

  defp normalize_all(entries, mod, source) do
    Enum.flat_map(entries, fn entry ->
      case new(entry) do
        {:ok, tab} ->
          [%{tab | module: mod}]

        {:error, reason} ->
          warn_once({:invalid, source, entry_id(entry)}, "#{source}: tab ignored, #{reason}")
          []
      end
    end)
  end

  defp entry_id(entry) when is_map(entry), do: Map.get(entry, :id)
  defp entry_id(entry) when is_list(entry), do: if(Keyword.keyword?(entry), do: entry[:id])
  defp entry_id(_entry), do: nil

  @doc """
  Normalise one entry (a map or a keyword list). Returns `{:error, reason}`
  (a string) for anything that is not a valid tab.
  """
  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new(entry) when is_list(entry) do
    if Keyword.keyword?(entry),
      do: new(Map.new(entry)),
      else: {:error, "expected a map or a keyword list"}
  end

  def new(entry) when is_map(entry) and not is_struct(entry) do
    with :ok <- check_keys(entry),
         {:ok, id} <- check_id(entry[:id]),
         :ok <- check_label(entry[:label]),
         :ok <- check_string_or_nil(:icon, entry[:icon]),
         :ok <- check_string_or_nil(:after, entry[:after]),
         :ok <- check_string_or_nil(:permission, entry[:permission]),
         :ok <- check_visible(entry[:visible]),
         {:ok, live_view} <- check_live_view(entry[:live_view]) do
      {:ok,
       %__MODULE__{
         id: id,
         label: entry.label,
         icon: entry[:icon] || "hero-squares-2x2",
         after: entry[:after],
         permission: entry[:permission],
         visible: entry[:visible],
         live_view: live_view
       }}
    end
  end

  def new(_entry), do: {:error, "expected a map or a keyword list"}

  defp check_keys(entry) do
    case Map.keys(entry) -- @fields do
      [] -> :ok
      unknown -> {:error, "unknown keys #{inspect(unknown)}"}
    end
  end

  defp check_id(id) when id in @reserved_ids, do: {:error, "the id #{inspect(id)} is core's"}

  defp check_id(id) when is_binary(id) do
    if Regex.match?(@id_format, id),
      do: {:ok, id},
      else: {:error, "the id #{inspect(id)} is not a URL segment (a-z, 0-9, - and _)"}
  end

  defp check_id(id), do: {:error, "the id must be a string, got #{inspect(id)}"}

  defp check_label(label) when is_binary(label) and label != "", do: :ok
  defp check_label({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: :ok
  defp check_label(label) when is_function(label, 0), do: :ok

  defp check_label(_label),
    do: {:error, "the label must be a string, an {m, f, a} or a zero-arity function"}

  defp check_string_or_nil(_key, nil), do: :ok
  defp check_string_or_nil(_key, value) when is_binary(value) and value != "", do: :ok
  defp check_string_or_nil(key, _value), do: {:error, "#{key} must be a string"}

  defp check_visible(nil), do: :ok
  defp check_visible({m, f}) when is_atom(m) and is_atom(f), do: :ok
  defp check_visible(fun) when is_function(fun, 1), do: :ok

  defp check_visible(_visible),
    do: {:error, "visible must be {module, function} or a one-argument function"}

  defp check_live_view(nil), do: {:ok, nil}

  defp check_live_view({mod, action}) when is_atom(mod) and is_atom(action),
    do: {:ok, {mod, action}}

  defp check_live_view(mod) when is_atom(mod), do: {:ok, {mod, :index}}
  defp check_live_view(_live_view), do: {:error, "live_view must be a module or {module, action}"}

  @doc false
  def drop_duplicates(tabs) do
    {kept, _seen} =
      Enum.reduce(tabs, {[], MapSet.new()}, fn tab, {kept, seen} ->
        if MapSet.member?(seen, tab.id) do
          warn_once(
            {:duplicate, tab.id, tab.module},
            "the tab #{inspect(tab.id)} of #{source_name(tab)} is already declared, ignored"
          )

          {kept, seen}
        else
          {[tab | kept], MapSet.put(seen, tab.id)}
        end
      end)

    Enum.reverse(kept)
  end

  defp source_name(%{module: nil}), do: "the host config"
  defp source_name(%{module: mod}), do: inspect(mod)

  @doc "The tab's label for this render."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{label: label}) when is_binary(label), do: label

  def label(%__MODULE__{id: id, label: label}) do
    case call_label(label) do
      text when is_binary(text) -> text
      _other -> fallback_label(id, "returned something that is not a string")
    end
  rescue
    error -> fallback_label(id, "raised #{inspect(error.__struct__)}")
  catch
    kind, _reason -> fallback_label(id, "failed (#{kind})")
  end

  defp call_label({m, f, a}), do: apply(m, f, a)
  defp call_label(fun), do: fun.()

  defp fallback_label(id, detail) do
    warn_once({:label, id}, "the label of the tab #{inspect(id)} #{detail}")
    id
  end

  @doc """
  Whether `scope` is offered the tab: its `:permission` held and its
  `:visible` true. Fails closed — a check that raises hides the tab.
  """
  @spec visible?(t(), term()) :: boolean()
  def visible?(%__MODULE__{} = tab, scope) do
    permitted?(tab, scope) and call_visible(tab, scope)
  rescue
    error ->
      warn_once(
        {:permission, tab.id},
        "the permission check of the tab #{inspect(tab.id)} raised #{inspect(error.__struct__)}"
      )

      false
  catch
    kind, _reason ->
      warn_once(
        {:permission, tab.id},
        "the permission check of the tab #{inspect(tab.id)} failed (#{kind})"
      )

      false
  end

  defp permitted?(%{permission: nil}, _scope), do: true
  defp permitted?(_tab, nil), do: false

  defp permitted?(%{permission: key}, scope),
    do: Scope.can?(scope, key)

  defp call_visible(%{visible: nil}, _scope), do: true

  defp call_visible(%{id: id, visible: visible}, scope) do
    result =
      case visible do
        {m, f} -> apply(m, f, [scope])
        fun -> fun.(scope)
      end

    result == true
  rescue
    error ->
      warn_once(
        {:visible, id},
        "the visibility check of the tab #{inspect(id)} raised #{inspect(error.__struct__)}"
      )

      false
  catch
    kind, _reason ->
      warn_once({:visible, id}, "the visibility check of the tab #{inspect(id)} failed (#{kind})")
      false
  end

  # The strip renders on every page view; one line per problem is enough.
  defp warn_once(key, message) do
    pterm = {__MODULE__, :warned, key}

    unless :persistent_term.get(pterm, false) do
      :persistent_term.put(pterm, true)
      Logger.warning("[ProfileSettingsTab] " <> message)
    end

    :ok
  end
end
