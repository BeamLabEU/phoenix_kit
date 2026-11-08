defmodule PhoenixKitWeb.PageSize do
  @moduledoc """
  Rows per page for the admin's lists: one size per person, remembered.

  A person picks 10, 25, 50, 100 or Auto (as many rows as fit the screen) in
  any list's footer, and every list that uses this module opens at that size
  from then on, on any device. It is kept in their `PhoenixKit.Users.ViewPrefs`
  under `"admin.lists"`.

  The size still lives in the URL, through `PhoenixKitWeb.Live.UrlState`: the
  saved size becomes the list's default for that person, so a URL without
  `per_page` (the menu, a bookmark, "Clear Filters") opens at it and leaves it
  out of the address. A link that names another size still wins, without
  changing what is saved.

  ## In a list

      use PhoenixKitWeb.Live.UrlState,
        params: [page: [default: 1, cast: :integer, min: 1]] ++ PhoenixKitWeb.PageSize.url_params()

      def mount(_params, _session, socket) do
        {:ok, socket |> ... |> PhoenixKitWeb.PageSize.mount()}
      end

      def handle_event("change_per_page", params, socket),
        do: {:noreply, PhoenixKitWeb.PageSize.handle_change(params, socket)}

  and `<.pagination_bar>` as the list's footer, with the table's id for Auto.
  A list in `:history` mode applies the saved size once the client connects.
  """

  require Logger

  import PhoenixKitWeb.Live.UrlState, only: [push_url_state: 2, put_url_state_default: 3]

  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKitWeb.Actor

  @sizes [10, 25, 50, 100]
  @default 25
  @prefs_key "admin.lists"
  @field "page_size"

  @doc "The sizes every list offers, besides Auto."
  @spec sizes() :: [pos_integer()]
  def sizes, do: @sizes

  @doc "The size of a list for a person who has not picked one."
  @spec default() :: pos_integer()
  def default, do: @default

  @doc """
  The `PhoenixKitWeb.Live.UrlState` params a list needs: `per_page` and the
  Auto flag (`?fit=true`). Append them to the list's own.
  """
  @spec url_params() :: keyword()
  def url_params do
    [
      # Allowlisted rather than bounded: an integer out of the URL is a LIMIT.
      per_page: [default: @default, cast: :integer, in: @sizes],
      # Only the flag lives here; the size Auto resolved to is `per_page`.
      auto_fit: [default: false, cast: :boolean, url_key: "fit"]
    ]
  end

  @doc """
  The person's saved choice: a size, `:auto`, or `nil` when they have none.
  Anything else stored there reads as none.
  """
  @spec saved(ViewPrefs.user()) :: pos_integer() | :auto | nil
  def saved(user) do
    case ViewPrefs.get(user, @prefs_key)[@field] do
      "auto" -> :auto
      size when size in @sizes -> size
      _other -> nil
    end
  end

  @doc """
  Makes the signed-in person's saved size the list's default. Call it in
  `mount/3`, after which the first `handle_params` reads the URL with it.
  """
  @spec mount(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket) do
    choice = saved(Actor.uuid(socket))

    socket
    |> Phoenix.Component.assign(:page_size_saved, choice)
    |> put_defaults(choice)
  end

  @doc """
  The footer selector's `change_per_page` event.

    * A size picked by hand is saved, becomes the default, and turns Auto off.
    * "Auto" is saved and raises the flag; the `PageSizeAutoFit` hook then
      measures and sends the size that fits, tagged `"auto"`.
    * That measured size moves the list and saves nothing: Auto is the choice,
      and the size changes with the window.

  Anything else is ignored.
  """
  @spec handle_change(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_change(%{"per_page" => "auto"}, socket) do
    socket |> pick(:auto) |> push_url_state(auto_fit: true)
  end

  def handle_change(%{"per_page" => raw} = params, socket) when is_binary(raw) do
    case {Integer.parse(raw), Map.has_key?(params, "auto")} do
      {{size, ""}, true} when size in @sizes ->
        push_url_state(socket, per_page: size)

      {{size, ""}, false} when size in @sizes ->
        socket |> pick(size) |> push_url_state(per_page: size, auto_fit: false)

      _ ->
        socket
    end
  end

  def handle_change(_params, socket), do: socket

  defp pick(socket, choice) do
    if socket.assigns[:page_size_saved] != choice, do: save(Actor.uuid(socket), choice)

    socket
    |> Phoenix.Component.assign(:page_size_saved, choice)
    |> put_defaults(choice)
  end

  defp put_defaults(socket, nil), do: socket
  defp put_defaults(socket, :auto), do: put_url_state_default(socket, :auto_fit, true)

  defp put_defaults(socket, size) do
    socket
    |> put_url_state_default(:per_page, size)
    |> put_url_state_default(:auto_fit, false)
  end

  # A failed save costs only the memory of the choice: the list still moves.
  defp save(nil, _choice), do: :ok

  defp save(user, choice) do
    value = if choice == :auto, do: "auto", else: choice

    case ViewPrefs.put(user, @prefs_key, %{@field => value}) do
      {:ok, _prefs} -> :ok
      {:error, :no_user} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  end

  # The reason's shape only: a database error can carry the query's values.
  defp log_failure(reason) do
    Logger.warning("[PageSize] could not save the page size: #{shape(reason)}")
  end

  defp shape(%{__struct__: mod}), do: inspect(mod)
  defp shape(reason) when is_atom(reason), do: inspect(reason)
  defp shape(_reason), do: "an error"
end
