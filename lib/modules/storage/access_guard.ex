defmodule PhoenixKit.Modules.Storage.AccessGuard do
  @moduledoc """
  A host's or a module's say in whether a stored file may be served to the
  person asking.

  A file can belong to something with its own audience: a protected post's
  pictures, an order's attachment. The kit's file routes know the file's
  library and its token, not that. A guard does: the kit asks it before it
  serves a file.

  ## Declaring a guard

  In the host's config, one `{module, function}` or a list of them:

      config :phoenix_kit, :file_access_guard, {MyApp.Files, :access}
      config :phoenix_kit, :file_access_guard, [{MyApp.Files, :access}, {MyApp.Orders, :file_access}]

  Or in a module package, the optional `c:PhoenixKit.Module.file_access_guard/2`
  callback (asked for every registered module, switched on or off: a disabled
  module's content keeps its audience).

  Every guard is called as `fun.(file, conn)`:

    * `file` — the `%PhoenixKit.Modules.Storage.File{}` asked for (its `uuid`,
      `library_uuid`, `user_uuid`, `metadata`, …);
    * `conn` — the request: `conn.assigns.phoenix_kit_current_user` /
      `:phoenix_kit_current_scope` when someone is signed in (the file routes run
      in the kit's browser pipeline), and the request cookies
      (`Plug.Conn.fetch_cookies/1` if you need them).

  It answers one of:

    * `:allow` — no objection: the file is served exactly as without a guard
      (shared caches may keep a public file);
    * `:private` — this person may see it, but it is not for everyone: it is
      served with `cache-control: private, no-store` and through the app,
      never as a redirect to a bucket URL;
    * `:deny` — answered as a missing file: the same 404, with
      `cache-control: private, no-store`.

  Any `:deny` wins, then any `:private`. A guard is asked about every file, so
  answer `:allow` quickly for files that are not yours (a lookup by
  `file.uuid` on an index, not a scan); it runs inside the request, once per
  file response (each thumbnail of a page is one).

  ## What is guarded

  `GET /file/:uuid/:variant/:token` (the original and every variant,
  thumbnails included), `GET /api/files/:uuid/info`,
  `GET /api/files/:uuid/unedited` and the image tiles
  (`/tiles/...`). Not guarded: a file in a public bucket reached at the
  bucket's own URL (`Storage.get_public_url/2` and a CDN URL point there, past
  the app), which a guarded file should therefore not be given; and the kit's
  own admin screens (the media browser), whose access is the admin's.

  ## Fails closed

  A guard that raises, exits, throws or answers anything else is a `:deny`
  for that request, and the log names the guard and the exception's module
  (never the request). With no guard (the default) nothing is called and
  every file is served as it always was.
  """

  require Logger

  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.ModuleRegistry

  @type answer :: :allow | :private | :deny

  @doc """
  The answer for `file` and `conn`: `:allow` when no guard is declared.
  """
  @spec check(struct(), Plug.Conn.t()) :: answer()
  def check(file, conn) do
    case guards() do
      [] -> :allow
      guards -> guards |> Enum.map(&ask(&1, file, conn)) |> combine()
    end
  end

  @doc false
  @spec combine([answer()]) :: answer()
  def combine(answers) do
    cond do
      :deny in answers -> :deny
      :private in answers -> :private
      true -> :allow
    end
  end

  @doc """
  Every guard in force: the configured ones, then those of registered modules
  that implement `c:PhoenixKit.Module.file_access_guard/2`.
  """
  @spec guards() :: [{module(), atom()}]
  def guards, do: configured() ++ module_guards()

  defp configured do
    case Application.get_env(:phoenix_kit, :file_access_guard) do
      nil -> []
      {mod, fun} = guard when is_atom(mod) and is_atom(fun) -> [guard]
      list when is_list(list) -> list
      _other -> [:invalid]
    end
  end

  defp module_guards do
    for mod <- ModuleRegistry.all_modules(),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :file_access_guard, 2),
        do: {mod, :file_access_guard}
  rescue
    _ -> []
  end

  defp ask({mod, fun} = guard, file, conn) when is_atom(mod) and is_atom(fun) do
    case apply(mod, fun, [file, conn]) do
      answer when answer in [:allow, :private, :deny] ->
        answer

      other ->
        denied(guard, "returned " <> LogSafe.shape(other))
    end
  rescue
    error -> denied(guard, "raised " <> LogSafe.exception_label(error))
  catch
    kind, _reason -> denied(guard, "failed (#{kind})")
  end

  defp ask(guard, _file, _conn),
    do: denied(guard, "is not a {module, function} pair")

  defp denied(guard, what) do
    Logger.warning(
      "[PhoenixKit] file_access_guard #{guard_label(guard)} #{what}; the file was not served"
    )

    :deny
  end

  defp guard_label({mod, fun}) when is_atom(mod) and is_atom(fun), do: "#{inspect(mod)}.#{fun}/2"
  defp guard_label(_other), do: "(invalid entry)"
end
