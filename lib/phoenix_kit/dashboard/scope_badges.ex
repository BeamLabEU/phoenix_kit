defmodule PhoenixKit.Dashboard.ScopeBadges do
  @moduledoc """
  Badges on admin menu entries whose number depends on who is looking.

  The tab registry holds one `PhoenixKit.Dashboard.Tab` per id for everybody, so a
  count that differs per person (their unread orders, their open requests) cannot live
  on the tab. A host application names a module that computes those counts for the
  person viewing the menu:

      # config/config.exs
      config :phoenix_kit, :scope_badges, MyApp.MenuBadges

  The module implements this behaviour:

      defmodule MyApp.MenuBadges do
        @behaviour PhoenixKit.Dashboard.ScopeBadges

        alias PhoenixKit.Dashboard.Badge
        alias PhoenixKit.Users.Auth.Scope

        @impl true
        def badges(scope) do
          counts = MyApp.ReadStates.unread_counts(Scope.user_uuid(scope))

          %{
            admin_orders: Badge.count(counts.orders, color: :primary, max: 99),
            admin_rfqs: Badge.count(counts.rfqs, color: :primary, max: 99)
          }
        end
      end

  `{MyApp.MenuBadges, :function_name}` works too, when the function is not called
  `badges/1`.

  ## What the sidebar does with it

    * It calls `badges/1` **once per sidebar render**, with the viewer's scope, after
      every gate has run: a person who may not open a tab is never shown its number,
      and nothing is computed for a visitor who gets no menu. Count everything in one
      query.
    * Keys are tab ids, the ones your tabs have in `:admin_dashboard_tabs` (or a
      module's, or core's). The value replaces the tab's `badge`; `nil` takes it away.
      Keys naming no tab on the menu are ignored, as is a value that is not a
      `PhoenixKit.Dashboard.Badge` (with a warning).
    * A raise, exit or throw in `badges/1`, or an answer that is not a map, is logged
      (the exception's module, never its message) and the menu is drawn with the badges
      the tabs already had. A broken count never takes the menu down.

  The sidebar also redraws whenever the page itself re-renders (any event the page
  handles), so keep `badges/1` cheap.

  ## Live updates

  When a count changes, call `changed/1` with the uuid of the account whose counts
  changed:

      PhoenixKit.Dashboard.ScopeBadges.changed(user_uuid)

  Every open admin page signed in as that account redraws its menu, calling `badges/1`
  again. Nothing to subscribe to: the page already listens on that account's scope
  topic (`PhoenixKit.Users.ScopeNotifier`), and the message never reaches the page's
  own `handle_info/2`. A burst of calls is drawn once per page when they arrive
  together.

  The uuid is the one the session is signed in as, `Scope.user_uuid/1`. In a session
  acting for an organization that is the organization, not the person.
  """

  require Logger

  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.Dashboard.{Badge, Tab}
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.ScopeNotifier

  @doc """
  The badges `scope` should see, as a map of tab id to `PhoenixKit.Dashboard.Badge`, or
  `nil` for no badge on that tab.
  """
  @callback badges(Scope.t()) :: %{optional(term()) => Badge.t() | nil}

  @doc """
  Puts the host application's per-viewer badges onto `tabs`.

  Calls the configured `badges/1` once. With nothing configured, `tabs` comes back
  unchanged.
  """
  @spec put_badges([Tab.t()], Scope.t() | nil) :: [Tab.t()]
  def put_badges([], _scope), do: []

  def put_badges(tabs, scope) do
    case loader() do
      nil -> tabs
      {module, function} -> merge(tabs, load(module, function, scope))
    end
  end

  @doc """
  Tells every open admin page signed in as `user` to redraw its menu badges.

  Takes a `PhoenixKit.Users.Auth.User` or a user uuid; anything else is ignored.
  Always returns `:ok`.
  """
  @spec changed(User.t() | String.t() | nil) :: :ok
  def changed(%User{uuid: uuid}), do: changed(uuid)
  def changed(uuid) when is_binary(uuid), do: ScopeNotifier.broadcast_badges_changed(uuid)
  def changed(_), do: :ok

  @doc false
  # The configured loader as `{module, function}`, or `nil`.
  @spec loader() :: {module(), atom()} | nil
  def loader do
    case Application.get_env(:phoenix_kit, :scope_badges) do
      nil -> nil
      {module, function} when is_atom(module) and is_atom(function) -> {module, function}
      module when is_atom(module) -> {module, :badges}
      other -> misconfigured(other)
    end
  end

  defp misconfigured(value) do
    Logger.warning(
      "[ScopeBadges] config :phoenix_kit, :scope_badges must be a module or " <>
        "{module, function}, got #{inspect(value)}; no menu badges are added"
    )

    nil
  end

  defp load(module, function, scope) do
    case Kernel.apply(module, function, [scope]) do
      badges when is_map(badges) ->
        badges

      other ->
        Logger.warning(
          "[ScopeBadges] #{inspect(module)}.#{function}/1 returned #{shape(other)}, not a map"
        )

        %{}
    end
  rescue
    error ->
      Logger.warning(
        "[ScopeBadges] #{inspect(module)}.#{function}/1 failed: #{LogSafe.exception_label(error)}"
      )

      %{}
  catch
    kind, _reason when kind in [:exit, :throw] ->
      Logger.warning("[ScopeBadges] #{inspect(module)}.#{function}/1 failed with #{kind}")
      %{}
  end

  defp merge(tabs, badges) when map_size(badges) == 0, do: tabs

  defp merge(tabs, badges) do
    Enum.map(tabs, fn %{id: id} = tab ->
      case Map.fetch(badges, id) do
        {:ok, %Badge{} = badge} ->
          %{tab | badge: badge}

        {:ok, nil} ->
          %{tab | badge: nil}

        {:ok, other} ->
          Logger.warning(
            "[ScopeBadges] badge for #{inspect(id)} is #{shape(other)}, not a " <>
              "PhoenixKit.Dashboard.Badge; the tab keeps its own"
          )

          tab

        :error ->
          tab
      end
    end)
  end

  # Only the kind of value: the host's data stays out of the log.
  defp shape(value) when is_integer(value), do: "an integer"
  defp shape(value) when is_binary(value), do: "a string"
  defp shape(value) when is_list(value), do: "a list"
  defp shape(%module{}), do: "a #{inspect(module)} struct"
  defp shape(value) when is_atom(value), do: "an atom"
  defp shape(_value), do: "an unexpected value"
end
