defmodule PhoenixKitWeb.FileAccessGuardTest do
  @moduledoc """
  `config :phoenix_kit, :file_access_guard` and `c:PhoenixKit.Module.file_access_guard/2`
  (`PhoenixKit.Modules.Storage.AccessGuard`): the file routes ask the guards before
  serving, every variant included; `:deny` is the 404 of a missing file, `:private` is
  served `private, no-store` and through the app; unset, nothing changes.

  End to end through `FileController.show/2` from real stored bytes.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{AccessGuard, URLSigner}
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  @buckets_cache :phoenix_kit_buckets_cache
  @answers {__MODULE__, :answers}

  defmodule Guard do
    @moduledoc false
    # Answers what the test put for the file's uuid, `:allow` for any other file.
    def access(file, conn) do
      send(self(), {:guard_asked, file.uuid, conn.method})

      case Map.get(
             :persistent_term.get({PhoenixKitWeb.FileAccessGuardTest, :answers}, %{}),
             file.uuid
           ) do
        :raise -> raise ArgumentError, "secret-#{file.uuid}"
        nil -> :allow
        answer -> answer
      end
    end
  end

  defmodule GuardingModule do
    @moduledoc false
    def module_key, do: "file_access_guard_test"
    def module_name, do: "File access guard test"
    def enabled?, do: false
    def file_access_guard(file, conn), do: Guard.access(file, conn)
  end

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_access_guard_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "access-guard-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      :persistent_term.erase(@answers)
      Application.delete_env(:phoenix_kit, :file_access_guard)
      File.rm_rf(tmp_root)
    end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "guard-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{guarded: store!(owner, "guarded #{n}"), other: store!(owner, "other #{n}")}
  end

  defp store!(owner, content) do
    source = Path.join(System.tmp_dir!(), "pk_guard_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "image", owner.uuid, checksum, "jpg", "p.jpg", [])

    File.rm(source)
    file
  end

  defp show(file, variant \\ "original") do
    params = %{
      "file_uuid" => file.uuid,
      "variant" => variant,
      "token" => URLSigner.generate_token(file.uuid, variant)
    }

    FileController.show(conn(:get, "/"), params)
  end

  defp answer(file, value),
    do:
      :persistent_term.put(
        @answers,
        Map.put(:persistent_term.get(@answers, %{}), file.uuid, value)
      )

  defp config_guard, do: Application.put_env(:phoenix_kit, :file_access_guard, {Guard, :access})

  defp response(conn),
    do: {conn.status, Plug.Conn.get_resp_header(conn, "cache-control"), conn.resp_body}

  test "unset: nothing is asked and every variant is served as before", %{guarded: file} do
    assert AccessGuard.guards() == []

    for variant <- ["original", "thumbnail"] do
      conn = show(file, variant)
      assert conn.status == 200
      refute_received {:guard_asked, _, _}
    end
  end

  test ":allow serves exactly as without a guard", %{guarded: file} do
    unset = for variant <- ["original", "thumbnail"], do: response(show(file, variant))

    config_guard()
    answer(file, :allow)
    guarded = for variant <- ["original", "thumbnail"], do: response(show(file, variant))

    assert guarded == unset
    assert_received {:guard_asked, uuid, "GET"}
    assert uuid == file.uuid
  end

  test ":deny is the 404 of a missing file, for the original and every variant",
       %{guarded: file, other: other} do
    config_guard()
    answer(file, :deny)

    for variant <- ["original", "thumbnail", "medium"] do
      conn = show(file, variant)
      assert conn.status == 404
      assert conn.resp_body == "File or variant not found"
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    # Another file is the guard's to allow.
    assert show(other).status == 200
  end

  test ":private is served, never to a shared cache", %{guarded: file} do
    config_guard()
    answer(file, :private)

    conn = show(file)
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]

    # A size not made yet answers with a stand-in that is never kept at all.
    conn = show(file, "thumbnail")
    assert conn.status == 200
    assert [control] = Plug.Conn.get_resp_header(conn, "cache-control")
    assert control =~ "no-store"
    refute control =~ "public"
  end

  test "a guard that raises or answers something else fails closed, logging no request data",
       %{guarded: file} do
    config_guard()

    for bad <- [:raise, :maybe] do
      answer(file, bad)
      log = capture_log(fn -> assert show(file).status == 404 end)
      assert log =~ "file_access_guard"
      refute log =~ "secret-"
    end
  end

  test "a list of guards: any :deny wins", %{guarded: file} do
    answer(file, :private)

    Application.put_env(:phoenix_kit, :file_access_guard, [
      {Guard, :access},
      {__MODULE__.AlwaysDeny, :access}
    ])

    assert show(file).status == 404
  end

  defmodule AlwaysDeny do
    @moduledoc false
    def access(_file, _conn), do: :deny
  end

  test "a registered module's guard is asked, even while the module is off", %{guarded: file} do
    :ok = ModuleRegistry.register(GuardingModule)
    on_exit(fn -> ModuleRegistry.unregister(GuardingModule) end)
    answer(file, :deny)

    assert {GuardingModule, :file_access_guard} in AccessGuard.guards()
    assert show(file).status == 404
  end

  test "combine/1: :deny, then :private, then :allow" do
    assert AccessGuard.combine([]) == :allow
    assert AccessGuard.combine([:allow, :private]) == :private
    assert AccessGuard.combine([:private, :deny, :allow]) == :deny
  end
end
