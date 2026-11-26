defmodule PhoenixKitWeb.LlmsTxtSectionsTest do
  @moduledoc """
  `config :phoenix_kit, llms_txt_sections: {Mod, :fun}`: the host's own sections of
  `/llms.txt`, through the real endpoint and router. Unset, the file is unchanged.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.LlmsTxt
  alias PhoenixKit.Modules.Languages

  defmodule Host do
    @moduledoc false

    def binary(ctx) do
      send(ctx_owner(), {:called, ctx})
      "## Shop\n\nWe sell paper.\n"
    end

    def list(_ctx) do
      send(ctx_owner(), :called)

      [
        %{title: "Products", body: "- [Paper](https://shop.test/paper)"},
        %{title: "Contact", body: "Write to us."}
      ]
    end

    def raises(_ctx), do: raise(ArgumentError, "secret-sentinel-#{:erlang.unique_integer()}")
    def throws(_ctx), do: throw(:nope)
    def kills(_ctx), do: Process.exit(self(), :kill)
    def bad_shape(_ctx), do: %{not: :a_section}
    def bad_list(_ctx), do: [%{title: "only a title"}]

    def slow(_ctx) do
      Process.sleep(1_000)
      "too late"
    end

    defp ctx_owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  setup do
    KeyTestSupport.start_cache_registry!()

    start_supervised!(
      Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
    )

    start_supervised!(
      Supervisor.child_spec({PhoenixKit.Cache, name: :llms_txt_sections}, id: :llms_cache)
    )

    {:ok, _} = Crawlers.enable_module()
    switch(:public, false)
    KeyTestSupport.put_setting("site_url", "https://shop.test")
    KeyTestSupport.put_setting("project_title", "Acme Print")
    :persistent_term.put({Host, :owner}, self())

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :llms_txt_sections)
      Application.delete_env(:phoenix_kit, :llms_txt_sections_timeout)
      :persistent_term.erase({Host, :owner})
    end)

    :ok
  end

  defp sections(fun), do: Application.put_env(:phoenix_kit, :llms_txt_sections, {Host, fun})

  defp fetch(conn, path \\ "/llms.txt"),
    do: conn |> with_client_ip(KeyTestSupport.unique_ip()) |> get(path)

  test "unset: the file is exactly as before", %{conn: conn} do
    conn = fetch(conn)
    assert conn.status == 200
    assert conn.resp_body == "# Acme Print\n"
  end

  test "a binary is appended after the operator's text", %{conn: conn} do
    sections(:binary)
    Crawlers.update_llms_txt_extra("> About us.")

    body = fetch(conn).resp_body

    assert body == "# Acme Print\n\n> About us.\n\n## Shop\n\nWe sell paper.\n"
    assert_received {:called, %{base_url: "https://shop.test", host: "shop.test", locale: locale}}
    assert is_binary(locale)
  end

  test "a list of sections is rendered as ## headings", %{conn: conn} do
    sections(:list)

    assert fetch(conn).resp_body ==
             "# Acme Print\n\n## Products\n\n- [Paper](https://shop.test/paper)\n\n## Contact\n\nWrite to us.\n"
  end

  test "an unknown Host never reaches the callback", %{conn: conn} do
    sections(:binary)
    conn = %{conn | host: "evil.test"}
    fetch(conn)

    assert_received {:called, %{host: "shop.test", base_url: "https://shop.test"}}
  end

  test "?lang= that is not an enabled language falls back to the primary one", %{conn: conn} do
    sections(:binary)
    fetch(conn, "/llms.txt?lang=zz-NOPE")

    assert_received {:called, %{locale: locale}}
    refute locale == "zz-NOPE"
    assert locale == Languages.primary_language_code()
  end

  for fun <- [:raises, :throws, :kills, :bad_shape, :bad_list] do
    test "#{fun}: logged, and the file is served without the sections", %{conn: conn} do
      sections(unquote(fun))

      log =
        capture_log(fn ->
          conn = fetch(conn)
          assert conn.status == 200
          assert conn.resp_body == "# Acme Print\n"
        end)

      assert log =~ "llms.txt"
      assert log =~ "served without its sections"
      refute log =~ "secret-sentinel"
    end
  end

  test "a callback past the deadline is cut off", %{conn: conn} do
    sections(:slow)
    Application.put_env(:phoenix_kit, :llms_txt_sections_timeout, 50)

    log =
      capture_log(fn ->
        {micros, conn} = :timer.tc(fn -> fetch(conn) end)
        assert conn.resp_body == "# Acme Print\n"
        assert micros < 900_000
      end)

    assert log =~ "did not answer within 50 ms"
  end

  test "a cut-off callback leaves nothing in the caller's mailbox" do
    sections(:slow)
    Application.put_env(:phoenix_kit, :llms_txt_sections_timeout, 20)
    ctx = %{base_url: "https://shop.test", host: "late.test", locale: "en"}

    capture_log(fn -> assert LlmsTxt.host_sections(ctx) == nil end)
    assert Process.info(self(), :message_queue_len) == {:message_queue_len, 0}
  end

  test "an answer is cached per host and locale; a failure is not" do
    sections(:list)
    ctx = %{base_url: "https://shop.test", host: "shop.test", locale: "en"}

    first = LlmsTxt.host_sections(ctx)
    assert_received :called
    assert LlmsTxt.host_sections(ctx) == first
    refute_received :called

    LlmsTxt.host_sections(%{ctx | locale: "et"})
    assert_received :called

    sections(:raises)
    other = %{ctx | host: "other.test"}

    capture_log(fn ->
      assert LlmsTxt.host_sections(other) == nil
      sections(:list)
      assert is_binary(LlmsTxt.host_sections(other))
    end)

    assert_received :called
  end

  test "a value that is not {module, function} is ignored with a warning" do
    Application.put_env(:phoenix_kit, :llms_txt_sections, "nope")

    assert capture_log(fn ->
             assert LlmsTxt.host_sections(%{base_url: "x", host: "x", locale: "en"}) == nil
           end) =~ "must be {module, function}"
  end

  describe "render_sections/1" do
    test "shapes" do
      assert LlmsTxt.render_sections("  ") == {:ok, ""}
      assert LlmsTxt.render_sections("x") == {:ok, "x\n"}
      assert LlmsTxt.render_sections([]) == {:ok, ""}
      assert LlmsTxt.render_sections([%{title: "A\nB", body: ""}]) == {:ok, "## A B\n"}
      assert LlmsTxt.render_sections(<<255>>) == :error
      assert LlmsTxt.render_sections([:x]) == :error
      assert LlmsTxt.render_sections(nil) == :error
    end
  end
end
