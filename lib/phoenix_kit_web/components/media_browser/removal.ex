defmodule PhoenixKitWeb.Components.MediaBrowser.Removal do
  @moduledoc false
  # The media browser's side of `PhoenixKit.Modules.Storage.RemovalGuard`: which
  # module stands guard, what it is asked and how its answers are read. Every
  # call into the host's module goes through here, so one place fails closed:
  # a module that raises, exits or answers a shape that is not the contract
  # removes nothing, and the log names the module and the exception, never
  # the request.

  require Logger

  alias PhoenixKit.Modules.Storage.RemovalGuard
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @doc "The guard of a browser: its `removal_guard` attribute (`false` = none), else the configured one."
  def guard(assigns) do
    case Map.get(assigns, :removal_guard) do
      false -> nil
      module when is_atom(module) and module not in [nil, true] -> module
      _ -> RemovalGuard.configured()
    end
  end

  @doc "The `ctx` the guard is given."
  def ctx(assigns, action, folder_uuid) do
    scope =
      case Map.get(assigns, :phoenix_kit_current_scope) do
        %Scope{} = scope -> scope
        _ -> Scope.for_user(Map.get(assigns, :phoenix_kit_current_user))
      end

    %{scope: scope, action: action, folder_uuid: folder_uuid}
  end

  @doc """
  `{:ok, places}` — the places the guard names for `uuids`, read into the
  contract's shape — or `:error` when it failed or answered something else.
  """
  def places(module, uuids, ctx) do
    with {:ok, answer} <- call(module, :places, fn -> module.places(uuids, ctx) end),
         {:ok, places} <- read_places(answer, Map.new(uuids, &{String.downcase(&1), &1})) do
      {:ok, places}
    else
      _ -> :error
    end
  end

  @doc "The text of the release button for this person, or nil (none, or the module failed)."
  def release_label(module, ctx) do
    if exported?(module, :release, 2) and exported?(module, :release_label, 1) do
      case call(module, :release_label, fn -> module.release_label(ctx) end) do
        {:ok, label} when is_binary(label) and label != "" -> label
        _ -> nil
      end
    end
  end

  @doc "`:ok`, or `{:error, message}` where `message` is a string to show or nil."
  def release(module, uuids, ctx) do
    if exported?(module, :release, 2) do
      case call(module, :release, fn -> module.release(uuids, ctx) end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, message}} when is_binary(message) -> {:error, message}
        _ -> {:error, nil}
      end
    else
      {:error, nil}
    end
  end

  defp exported?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  @default_timeout 5_000

  # The host's module runs in a process of its own, so one that hangs cannot
  # hold the page, and one that is killed cannot take it down: after the
  # timeout (`config :phoenix_kit, :file_removal_guard_timeout`, ms) it is
  # killed and the call fails closed, as it does when the process dies. Not
  # linked, so nothing it does reaches the page's process. It inherits what a
  # callback needs from the page: the Gettext locale, the logger metadata and
  # `$callers` (the Ecto sandbox in tests).
  defp call(module, what, fun) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]
    locale = Gettext.get_locale(PhoenixKitWeb.Gettext)
    default_locale = Gettext.get_locale()
    metadata = Logger.metadata()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
        Gettext.put_locale(default_locale)
        Logger.metadata(metadata)

        result =
          try do
            {:ok, fun.()}
          rescue
            exception -> {:failed, exception.__struct__}
          catch
            kind, _reason -> {:failed, kind}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:ok, _answer} = ok} ->
        Process.demonitor(monitor, [:flush])
        ok

      {^ref, {:failed, why}} ->
        Process.demonitor(monitor, [:flush])
        log_failure(module, what, why)
        :error

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        log_failure(module, what, :killed)
        :error
    after
      timeout() ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        log_failure(module, what, :timed_out)
        :error
    end
  end

  defp timeout do
    case Application.get_env(:phoenix_kit, :file_removal_guard_timeout, @default_timeout) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout
    end
  end

  defp log_failure(module, what, :timed_out) do
    Logger.error("MediaBrowser removal guard #{inspect(module)}.#{what} timed out")
  end

  defp log_failure(module, what, why) do
    Logger.error("MediaBrowser removal guard #{inspect(module)}.#{what} failed: #{inspect(why)}")
  end

  defp read_places(answer, requested) when is_list(answer) do
    answer
    |> Enum.reduce_while({:ok, []}, fn place, {:ok, acc} ->
      case read_place(place, requested) do
        {:ok, place} -> {:cont, {:ok, [place | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, places} -> {:ok, Enum.reverse(places)}
      :error -> :error
    end
  end

  defp read_places(_answer, _requested), do: :error

  # Uuids are compared in lower case and answered in the form they were asked.
  # A place for a file that was not asked about breaks the contract — a guard
  # that names files by some other key would otherwise leave a file in use
  # looking free — so the whole answer is refused.
  defp read_place(%{file_uuid: uuid} = place, requested) when is_binary(uuid) do
    case Map.fetch(requested, String.downcase(uuid)) do
      {:ok, asked} -> read_place_fields(asked, place)
      :error -> :error
    end
  end

  defp read_place(_place, _requested), do: :error

  # An unlabelled place is one the person may not see: nothing of it is kept.
  defp read_place_fields(uuid, %{label: label} = place) when is_binary(label) do
    {:ok,
     %{
       file_uuid: uuid,
       label: label,
       detail: text(Map.get(place, :detail)),
       href: safe_href(Map.get(place, :href))
     }}
  end

  defp read_place_fields(uuid, _place),
    do: {:ok, %{file_uuid: uuid, label: nil, detail: nil, href: nil}}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  # The link is the host's, opened in a new tab: a path of this site or an
  # http(s) address, never a `javascript:` or `data:` URL.
  defp safe_href(href) when is_binary(href) do
    cond do
      Routes.local_path?(href) -> href
      Regex.match?(~r{\Ahttps?://[^\s]+\z}i, href) -> href
      true -> nil
    end
  end

  defp safe_href(_href), do: nil
end
