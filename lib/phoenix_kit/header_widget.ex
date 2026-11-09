defmodule PhoenixKit.HeaderWidget do
  @moduledoc """
  A sticky LiveView a module puts into the admin header, before the notifications bell
  (`c:PhoenixKit.Module.header_widgets/0`).

  A module returns tuples; core normalises them into this struct
  (`PhoenixKit.ModuleRegistry.all_header_widgets/0`) and the admin layout renders each one
  with `Phoenix.Component.live_render/3` (`sticky: true`, `id: id`).

  ## Fields

    * `:live_view` - the LiveView module to render.
    * `:id` - the DOM id of the nested LiveView (not one the admin layout uses itself, see
      `reserved_ids/0`). Stable: a sticky LiveView keeps its state
      (and its PubSub subscriptions) across admin navigation only while the id is the same.
      Two widgets with one id cannot both be rendered; the first one registered wins.
    * `:session_fun` - `(layout_assigns -> session)`, called on every render of the
      layout with the layout's assigns. They include `:socket` (the parent LiveView's
      socket), `:phoenix_kit_current_scope` and `:phoenix_kit_current_user` (the user of
      the scope, filled in when the caller passed only the scope), `:current_locale`,
      `:current_locale_base` and `:impersonating?` (see `impersonating?/1`). It returns the
      session of the nested LiveView: a map with **string** keys and values that survive
      being signed into the page, so ids and strings, not structs. Or `nil`: no widget for
      this user, nothing is rendered (and no dock) and nothing is logged. Check what the
      user may see here, where the scope is at hand, rather than after the widget's process
      has started.
    * `:dock` - `true` when the widget uses the dock column (`#pk-dock`, see
      `PhoenixKitWeb.Components.AdminDock`). The column exists only while a rendered widget
      declares it.
    * `:module` - the module that declared the widget. Filled in by the registry.
    * `:session` - the result of `:session_fun`, filled in by
      `PhoenixKit.ModuleRegistry.header_widgets_for/1`.

  ## Authority

  The session is signed, not encrypted: whoever has the page can read it. Ids and strings the
  widget needs, never a secret or a token.

  The session is all the widget gets: a nested sticky LiveView is mounted without the
  `live_session`'s `on_mount` hooks and without `current_scope`, and for every signed-in user
  of an admin-layout page. The widget has to check the permission itself from the session
  (see `c:PhoenixKit.Module.header_widgets/0`).

  The keys `user_token`, `pk_session_accounts`, `pk_own_tokens`, `pk_impersonators`,
  `pk_organization_token`, `live_socket_id` and `phoenix_kit_session_uuid` are reserved
  (`reserved_session_keys/0`): they belong to the cookie session, which LiveView
  merges under the signed session of the nested LiveView, so a value here would hide the real
  one from the session and impersonation checks. They are dropped from the session (one
  warning per module and widget, without the values).

  `session_fun` receives the layout's assigns, **not** the cookie session and not the session
  token. A widget that needs the session reference or an impersonation check does it itself
  in its connected `mount/3`: LiveView merges the cookie session from `connect_info` into the
  session of every LiveView, so `PhoenixKit.Users.Auth.SessionRef.from_session/1` and
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` can be called there on the `session`
  argument (both arrive with the agent-execute PR; this branch does not depend on them).
  `:impersonating?` in the assigns is a hint for rendering: it is read from
  `scope.multi_session_accounts` and is always `false` while multi-session is off, so it is
  not a guarantee. Keep secrets out of the session map: a nested LiveView's session is
  signed, not encrypted.
  """

  # Keys of the browser's cookie session that authentication reads. The signed session of a
  # nested LiveView is merged OVER the cookie session (Phoenix.LiveView.Channel), so a widget
  # session carrying one of them would replace what `SessionRef.from_session/1` and
  # `MultiSession.impersonated?/1` read in the widget's `mount/3`.
  @reserved_session_keys ~w(user_token pk_session_accounts pk_own_tokens pk_impersonators pk_organization_token live_socket_id phoenix_kit_session_uuid)

  @doc "The session keys a widget's session function cannot set: they are dropped."
  @spec reserved_session_keys() :: [String.t()]
  def reserved_session_keys, do: @reserved_session_keys

  @type session_fun :: (map() -> map() | nil)

  @typedoc "What `c:PhoenixKit.Module.header_widgets/0` returns, one element per widget."
  @type entry ::
          {live_view :: module(), id :: String.t(), session_fun()}
          | {live_view :: module(), id :: String.t(), session_fun(), opts :: [dock: boolean()]}

  @type t :: %__MODULE__{
          module: module() | nil,
          live_view: module(),
          id: String.t(),
          session_fun: session_fun(),
          dock: boolean(),
          session: map() | nil
        }

  # DOM ids the admin layout already uses; a widget with one of them would clash with it.
  @reserved_ids ["pk-notifications-bell", "pk-dock", "admin-drawer"]

  @enforce_keys [:live_view, :id, :session_fun]
  defstruct [:module, :live_view, :id, :session_fun, :session, dock: false]

  @doc "The DOM ids of the admin layout that a widget may not use."
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @doc """
  Normalise one entry of `c:PhoenixKit.Module.header_widgets/0`.

  `{live_view, id, session_fun}` or `{live_view, id, session_fun, opts}` with
  `opts = [dock: boolean]`. Returns `{:error, reason}` (a string) for anything else.
  """
  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new({live_view, id, session_fun}), do: new({live_view, id, session_fun, []})

  def new({live_view, id, session_fun, opts}) do
    with :ok <- check_live_view(live_view),
         :ok <- check_id(id),
         :ok <- check_session_fun(session_fun),
         {:ok, dock} <- check_opts(opts) do
      {:ok, %__MODULE__{live_view: live_view, id: id, session_fun: session_fun, dock: dock}}
    end
  end

  def new(_entry) do
    {:error, "expected {live_view, id, session_fun} or {live_view, id, session_fun, opts}"}
  end

  @doc """
  Run the widget's session function against the layout's assigns.

  Returns `{:ok, widget}` with `:session` filled in, `:skip` when the function returned
  `nil` (no widget for this user), or `{:error, reason}` when the function raises or returns
  something `live_render/3` cannot take (not a map, or a key that is not a string).
  """
  @spec resolve_session(t(), map()) ::
          {:ok, t(), dropped_keys :: [String.t()]} | :skip | {:error, String.t()}
  def resolve_session(%__MODULE__{session_fun: fun} = widget, assigns) do
    case fun.(assigns) do
      nil ->
        :skip

      session when is_map(session) and not is_struct(session) ->
        if Enum.all?(session, fn {key, _} -> is_binary(key) end) do
          {dropped, kept} = Map.split(session, @reserved_session_keys)
          {:ok, %{widget | session: kept}, dropped |> Map.keys() |> Enum.sort()}
        else
          {:error, "the session has a key that is not a string"}
        end

      other ->
        {:error, "the session is #{describe_type(other)}, not a map"}
    end
  rescue
    error -> {:error, "the session function raised #{inspect(error.__struct__)}"}
  catch
    kind, _reason -> {:error, "the session function failed (#{kind})"}
  end

  # The function gets the layout's assigns (the user and scope among them), so what it
  # raises or returns can hold a person's data: a `KeyError` or `MatchError` message
  # prints the whole term. The log names the kind of failure and never the value.
  defp describe_type(%{__struct__: module}), do: "a #{inspect(module)} struct"
  defp describe_type(value) when is_list(value), do: "a list"
  defp describe_type(value) when is_tuple(value), do: "a tuple"
  defp describe_type(value) when is_binary(value), do: "a string"
  defp describe_type(value) when is_atom(value), do: "an atom"
  defp describe_type(_value), do: "of another type"

  @doc """
  True while acting through a borrowed account or an organization's slot.

  The layout passes this as `:impersonating?` to the session functions. The
  account list distinguishes accounts added with their own credentials (`own?`) from
  borrowed ones. Older lists without that field treat a non-root account as borrowed.
  Token-loaded organization provenance and impersonator attribution also count when the
  switcher is off. A widget that must not run for
  an operator borrowing a user's session returns `nil` from its session function when it is
  `true`.
  """
  @spec impersonating?(PhoenixKit.Users.Auth.Scope.t() | nil) :: boolean()
  def impersonating?(%{user: %{acting_user_uuid: uuid}}) when is_binary(uuid), do: true
  def impersonating?(%{impersonated_by_uuid: uuid}) when is_binary(uuid), do: true

  def impersonating?(%{multi_session_accounts: [_ | _] = accounts}) do
    Enum.any?(accounts, &(&1.active? and not Map.get(&1, :own?, &1.root?)))
  end

  def impersonating?(_scope), do: false

  defp check_live_view(live_view) when is_atom(live_view) and not is_nil(live_view) do
    if Code.ensure_loaded?(live_view) and function_exported?(live_view, :__live__, 0) do
      :ok
    else
      {:error, "#{inspect(live_view)} is not a LiveView module"}
    end
  end

  defp check_live_view(live_view), do: {:error, "#{inspect(live_view)} is not a LiveView module"}

  defp check_id(id) when id in @reserved_ids,
    do: {:error, "the id #{inspect(id)} is reserved by the admin layout"}

  defp check_id(id) when is_binary(id) and id != "", do: :ok
  defp check_id(id), do: {:error, "the id must be a non-empty string, got #{inspect(id)}"}

  defp check_session_fun(fun) when is_function(fun, 1), do: :ok
  defp check_session_fun(_fun), do: {:error, "the session function must take one argument"}

  defp check_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:dock] == [] do
      case Keyword.get(opts, :dock, false) do
        dock when is_boolean(dock) -> {:ok, dock}
        other -> {:error, ":dock must be a boolean, got #{inspect(other)}"}
      end
    else
      {:error, "the only option is :dock"}
    end
  end

  defp check_opts(_opts), do: {:error, "the options must be a keyword list"}
end
