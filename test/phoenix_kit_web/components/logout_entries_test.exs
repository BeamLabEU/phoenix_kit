defmodule PhoenixKitWeb.Components.LogoutEntriesTest do
  @moduledoc """
  DB-free unit verification for log-out entries across the account menus and
  for the `<.link>` contract across `lib/`:

  - Every log-out anchor in `UserDashboardNav.user_dropdown/1`,
    `AdminNav.admin_user_dropdown/1`, and `AdminNav.admin_user_info/1` must
    render as a CSRF-carrying DELETE (`data-method="delete"`, `data-csrf`,
    `data-to`) and never a LiveView navigation (`data-phx-link`).
  - Both avatar dropdowns carry `:current_locale` into their log-out targets.
  - No `<.link>` anywhere in `lib/` may combine `method=` with `navigate=` or
    `patch=`, because `Phoenix.Component.link/1` silently drops `method` and
    turns the link into a plain GET navigation.

  `async: false` because the locale test starts the globally named `:settings`
  cache so it runs identically with or without PostgreSQL.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.{AdminNav, UserDashboardNav}

  defp scope_fixture do
    user = %User{
      uuid: "019a0000-0000-7000-8000-000000000001",
      email: "logout-unit@example.com",
      is_active: true
    }

    account = fn ref, active? ->
      %{ref: ref, email: user.email, role: "User", active?: active?, root?: ref == "a"}
    end

    %Scope{
      user: user,
      authenticated?: true,
      cached_roles: ["User"],
      cached_permissions: MapSet.new(),
      multi_session_allowed?: true,
      multi_session_accounts: [account.("a", true), account.("b", false)]
    }
  end

  defp logout_anchors(html) do
    ~r/<a\b[^>]*\/users\/log-out[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
  end

  defp assert_delete_anchors(anchors) do
    assert anchors != []

    for tag <- anchors do
      assert tag =~ ~s(data-method="delete"), "log-out entry is a GET link: #{tag}"
      assert tag =~ ~r/data-csrf="[^"]+"/, "log-out entry carries no CSRF token: #{tag}"

      assert tag =~ ~r/data-to="[^"]*\/users\/log-out/,
             "log-out entry has no DELETE target: #{tag}"

      refute tag =~ "data-phx-link", "log-out entry is a LiveView navigation: #{tag}"
    end
  end

  # Extracts every `<.link ...>` opening tag while respecting balanced `{...}`
  # expressions (including nested `#{...}` interpolation and `<>`) and double-
  # quoted strings, so a `>` inside an attribute value does not terminate early.
  defp extract_link_opening_tags(source) do
    ~r/<\.link(?=\s|>)/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _len}] ->
      rest = binary_part(source, start, byte_size(source) - start)
      scan_opening_tag(rest, 0, false, [])
    end)
  end

  defp scan_opening_tag(<<>>, _brace_depth, _in_quote, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan_opening_tag(<<?>, _rest::binary>>, 0, false, acc),
    do: [?> | acc] |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan_opening_tag(<<?\\, ch, rest::binary>>, depth, true, acc),
    do: scan_opening_tag(rest, depth, true, [ch, ?\\ | acc])

  defp scan_opening_tag(<<?", rest::binary>>, depth, in_quote, acc),
    do: scan_opening_tag(rest, depth, not in_quote, [?" | acc])

  defp scan_opening_tag(<<?{, rest::binary>>, depth, false, acc),
    do: scan_opening_tag(rest, depth + 1, false, [?{ | acc])

  defp scan_opening_tag(<<?}, rest::binary>>, depth, false, acc) when depth > 0,
    do: scan_opening_tag(rest, depth - 1, false, [?} | acc])

  defp scan_opening_tag(<<ch, rest::binary>>, depth, in_quote, acc),
    do: scan_opening_tag(rest, depth, in_quote, [ch | acc])

  test "user_dropdown emits CSRF-bearing DELETE anchors for both log-out entries" do
    assigns = %{scope: scope_fixture()}

    html =
      rendered_to_string(~H"""
      <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="en" />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 2
    assert Enum.any?(anchors, &(&1 =~ ~r/data-to="[^"]*\/users\/log-out\?all=1"/))
    assert_delete_anchors(anchors)
  end

  test "admin_user_dropdown emits CSRF-bearing DELETE anchors for both log-out entries" do
    scope = scope_fixture()
    assigns = %{scope: scope, accounts: scope.multi_session_accounts}

    html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_dropdown
        scope={@scope}
        accounts={@accounts}
        multi_session_allowed?={true}
        current_path="/"
        current_locale="en"
      />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 2
    assert Enum.any?(anchors, &(&1 =~ ~r/data-to="[^"]*\/users\/log-out\?all=1"/))
    assert_delete_anchors(anchors)
  end

  test "admin_user_info emits a CSRF-bearing DELETE anchor for log-out" do
    assigns = %{scope: scope_fixture()}

    html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_info scope={@scope} />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 1
    assert_delete_anchors(anchors)
  end

  test "both dropdowns carry a non-default current_locale into their log-out targets" do
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    PhoenixKit.Cache.put(:settings, "languages_enabled", "true")

    scope = scope_fixture()
    assigns = %{scope: scope, accounts: scope.multi_session_accounts}

    user_html =
      rendered_to_string(~H"""
      <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="de-DE" />
      """)

    admin_html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_dropdown
        scope={@scope}
        accounts={@accounts}
        multi_session_allowed?={true}
        current_path="/"
        current_locale="de-DE"
      />
      """)

    expected = Routes.path("/users/log-out", locale: "de")
    assert expected =~ "/de/users/log-out"

    for html <- [user_html, admin_html] do
      anchors = logout_anchors(html)
      assert length(anchors) == 2
      assert Enum.any?(anchors, &(&1 =~ ~s(data-to="#{expected}")))
      assert Enum.any?(anchors, &(&1 =~ ~s(data-to="#{expected}?all=1")))
      assert_delete_anchors(anchors)
    end
  end

  test "no <.link> in lib/ combines method= with navigate= or patch=" do
    offenders =
      Path.wildcard("lib/**/*.{ex,heex}")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> extract_link_opening_tags()
        |> Enum.filter(fn tag ->
          String.contains?(tag, "method=") and
            (String.contains?(tag, "navigate=") or String.contains?(tag, "patch="))
        end)
        |> Enum.map(&{path, &1})
      end)

    assert offenders == [],
           "Found <.link> combining method= with navigate=/patch= (method is silently dropped): #{inspect(offenders)}"
  end
end
