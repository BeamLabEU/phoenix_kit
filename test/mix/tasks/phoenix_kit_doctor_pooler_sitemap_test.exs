defmodule Mix.Tasks.PhoenixKit.DoctorPoolerSitemapTest do
  @moduledoc """
  The doctor's decisions for two checks that used to guess.

  PgBouncer: the hostname/port heuristic called a pooler at `postgres:5432`
  "Direct PostgreSQL" and any port-less URL a pooler. The verdict now comes
  from the behavioral probe, says "could not tell" when it could not, and
  flags Oban's Postgres notifier, whose LISTEN/NOTIFY silently stops working
  behind transaction pooling.

  Sitemap: an upgraded host can declare the kit's root sitemap route a second
  time (1.7 told it to), and only one declaration ever runs; and a site with
  no `site_url` now serves its sitemap from the endpoint URL, which the
  operator should know.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor

  @where "port=5432, host=postgres"

  describe "pgbouncer_verdict/4" do
    test "transaction pooling warns, and names the default notifier" do
      assert {:warn, message} =
               Doctor.pgbouncer_verdict(:direct, :transaction_pooled, nil, @where)

      assert message =~ "Transaction pooling detected"
      assert message =~ "@disable_ddl_transaction"
      assert message =~ "Oban.Notifiers.PG"
    end

    test "an explicitly configured Postgres notifier is flagged too" do
      assert {:warn, message} =
               Doctor.pgbouncer_verdict(
                 :direct,
                 :transaction_pooled,
                 Oban.Notifiers.Postgres,
                 @where
               )

      assert message =~ "Postgres notifier"
    end

    test "a host already on the PG notifier is not nagged about it" do
      assert {:warn, message} =
               Doctor.pgbouncer_verdict(:direct, :transaction_pooled, Oban.Notifiers.PG, @where)

      refute message =~ "notifier"
    end

    test "no pooling detected never claims the database is direct" do
      assert {:pass, message} = Doctor.pgbouncer_verdict(:direct, :not_detected, nil, @where)
      assert message =~ "No transaction pooling detected"
      refute message =~ "Direct PostgreSQL"
    end

    test "a pooler-looking config with no pooling detected keeps the advice" do
      # An idle PgBouncer reuses one backend, so the probe cannot clear it.
      assert {:warn, message} =
               Doctor.pgbouncer_verdict(:maybe_pooled, :not_detected, nil, "port=6432")

      assert message =~ "session pooling"
      assert message =~ "@disable_ddl_transaction"
      assert message =~ "Oban.Notifiers.PG"
    end

    test "an inconclusive probe says so" do
      assert {:warn, message} =
               Doctor.pgbouncer_verdict(:direct, {:inconclusive, "timeout"}, nil, @where)

      assert message =~ "Could not tell"
      assert message =~ "timeout"
      assert message =~ "If transaction pooling is in use"
    end
  end

  describe "update_mode_verdict/1" do
    test "doctor's own update mode is expected" do
      assert {:pass, message} = Doctor.update_mode_verdict(false)
      assert message =~ "doctor temporarily enables"
    end

    test "host-configured update mode still warns" do
      assert {:warn, message} = Doctor.update_mode_verdict(true)
      assert message =~ "before doctor started"
    end
  end

  defp route(path, plug), do: %{verb: :get, path: path, plug: plug}

  describe "duplicate_root_route_findings/1" do
    test "a path declared twice names the one that answers and the dead one" do
      routes = [
        route("/sitemap.xml", HostWeb.SitemapController),
        route("/users", HostWeb.UserController),
        route("/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller)
      ]

      assert [finding] = Doctor.duplicate_root_route_findings(routes)
      assert finding =~ "GET /sitemap.xml is declared 2 times"
      assert finding =~ "HostWeb.SitemapController answers it"
      assert finding =~ "PhoenixKit.Modules.Sitemap.Web.Controller never runs"
    end

    test "llms.txt is checked too" do
      routes = [
        route("/llms.txt", PhoenixKit.Modules.Crawlers.Web.Controller),
        route("/llms.txt", HostWeb.LlmsController)
      ]

      assert [finding] = Doctor.duplicate_root_route_findings(routes)
      assert finding =~ "/llms.txt"
    end

    test "a repeat that points at the same controller and action is not reported" do
      # A host declares /sitemap.xml ahead of `scope "/:locale"` (otherwise
      # `:locale` captures "sitemap.xml"); the kit declares it again. Both lead
      # to the same controller and action, so there is nothing to delete.
      same = PhoenixKit.Modules.Sitemap.Web.Controller

      routes = [
        %{verb: :get, path: "/sitemap.xml", plug: same, plug_opts: :index_xml},
        %{verb: :get, path: "/sitemap.xml", plug: same, plug_opts: :index_xml}
      ]

      assert Doctor.duplicate_root_route_findings(routes) == []
    end

    test "the same controller with a different action is still reported" do
      same = PhoenixKit.Modules.Sitemap.Web.Controller

      routes = [
        %{verb: :get, path: "/sitemap.xml", plug: same, plug_opts: :index_xml},
        %{verb: :get, path: "/sitemap.xml", plug: same, plug_opts: :index_html}
      ]

      assert [finding] = Doctor.duplicate_root_route_findings(routes)
      assert finding =~ "declared 2 times"

      # Same controller on both sides: the action tells them apart.
      assert finding =~ "PhoenixKit.Modules.Sitemap.Web.Controller (:index_xml) answers it"

      assert finding =~
               "declaration by PhoenixKit.Modules.Sitemap.Web.Controller (:index_html) never runs"
    end

    test "only the declarations that differ from the winner are named" do
      kit = PhoenixKit.Modules.Sitemap.Web.Controller

      routes = [
        %{verb: :get, path: "/sitemap.xml", plug: kit, plug_opts: :index_xml},
        %{verb: :get, path: "/sitemap.xml", plug: kit, plug_opts: :index_xml},
        %{verb: :get, path: "/sitemap.xml", plug: HostWeb.SitemapController, plug_opts: :show}
      ]

      assert [finding] = Doctor.duplicate_root_route_findings(routes)
      assert finding =~ "declared 3 times"
      assert finding =~ "HostWeb.SitemapController never runs"
      refute finding =~ "#{inspect(kit)}, "
    end

    test "a real router with the host's early declaration and the kit's later one reports nothing" do
      defmodule DuplicateSitemapRouter do
        use Phoenix.Router

        get "/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller, :index_xml

        scope "/:locale" do
          get "/page", HostWeb.PageController, :show
        end

        get "/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller, :index_xml
      end

      assert Doctor.duplicate_root_route_findings(DuplicateSitemapRouter.__routes__()) == []
    end

    test "single declarations and other paths report nothing" do
      routes = [
        route("/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller),
        route("/about", HostWeb.PageController),
        route("/about", HostWeb.OtherController)
      ]

      assert Doctor.duplicate_root_route_findings(routes) == []
    end
  end

  describe "sitemap_base_url_finding/2" do
    test "nothing to report when site_url is set" do
      assert Doctor.sitemap_base_url_finding("https://example.com", "http://localhost:4000") ==
               nil
    end

    test "names the endpoint URL the sitemap falls back to" do
      finding = Doctor.sitemap_base_url_finding("", "https://shop.acme.dev")
      assert finding =~ "https://shop.acme.dev"
      assert finding =~ "Set site_url"
      refute finding =~ "development server"
    end

    test "a loopback fallback warns that production would 503" do
      finding = Doctor.sitemap_base_url_finding("", "http://localhost:4000")
      assert finding =~ "http://localhost:4000"
      assert finding =~ "localhost counts only on a development server"
      assert finding =~ "in production the sitemap answers 503"
    end

    test "says the sitemap 503s when there is nothing to fall back to" do
      assert Doctor.sitemap_base_url_finding("", "") =~ "503"
    end
  end
end
