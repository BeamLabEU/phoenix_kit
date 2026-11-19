defmodule PhoenixKitWeb.Components.PeoplePickerTest do
  @moduledoc """
  Core's people picker, in a host LiveView: picks reach the parent as the
  whole new list, a forged key picks nothing, a source can ask before a
  pick, `max: 1` replaces, and adding from a browsed or searched list
  leaves that list where it was (the boss, 2026-11-18: adding a person
  threw the list back to the top).
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.PeoplePicker
  alias PhoenixKitWeb.Components.PeoplePicker.UserSource

  defmodule FakeSource do
    @moduledoc false
    @behaviour PhoenixKitWeb.Components.PeoplePicker.Source

    @people for n <- 1..12,
                do: %{kind: "person", uuid: "p#{n}", label: "Person #{n}", sublabel: "p#{n}@x"}
    @teams [%{kind: "team", uuid: "t1", label: "Kitchen", icon: "hero-user-group"}]

    @impl true
    def groups(_ctx), do: [%{key: "team", label: "Teams"}, %{key: "person", label: "People"}]

    @impl true
    def page({:group, "person"}, cursor, limit, _ctx), do: slice(@people, cursor, limit)
    def page({:group, "team"}, cursor, limit, _ctx), do: slice(@teams, cursor, limit)

    def page({:search, text}, cursor, limit, _ctx),
      do: slice(Enum.filter(@people ++ @teams, &String.contains?(&1.label, text)), cursor, limit)

    @impl true
    def describe({"person", "ghost"}, _ctx), do: nil

    def describe({kind, uuid}, _ctx),
      do: Enum.find(@people ++ @teams, &(&1.kind == kind and &1.uuid == uuid))

    # p12 has no staff record yet: asks first, then picks p11 as "the record made".
    @impl true
    def pick({"person", "p12"}, _ctx),
      do: {:confirm, %{title: "Create a record?", text: "Person 12 has none.", confirm: "Create"}}

    def pick({"person", "p10"}, _ctx), do: {:error, "Their record is in the trash."}
    def pick(key, _ctx), do: {:ok, key}

    @impl true
    def confirm({"person", "p12"}, _ctx), do: {:ok, {"person", "p11"}}

    @impl true
    def me(_ctx), do: {"person", "p1"}

    defp slice(rows, cursor, limit) do
      offset = cursor || 0
      page = rows |> Enum.drop(offset) |> Enum.take(limit)
      {page, if(offset + limit < length(rows), do: offset + limit)}
    end
  end

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok,
       Phoenix.Component.assign(socket,
         keys: [],
         max: session["max"],
         changes: 0,
         tags: %{{"person", "p1"} => ["You", %{label: "Project owner", tone: :info}]}
       )}
    end

    def render(assigns) do
      ~H"""
      <div id="parent-keys">{Enum.map_join(@keys, ",", fn {k, u} -> "#{k}:#{u}" end)}</div>
      <div id="parent-changes">{@changes}</div>
      <form id="parent-form" phx-change="parent_changed">
        <.live_component
          module={PhoenixKitWeb.Components.PeoplePicker}
          id="pp"
          selected={@keys}
          source={PhoenixKitWeb.Components.PeoplePickerTest.FakeSource}
          name="thing[people][]"
          max={@max}
          tags={@tags}
          viewer_uuid="viewer"
        />
      </form>
      """
    end

    def handle_event("parent_changed", _params, socket),
      do: {:noreply, Phoenix.Component.update(socket, :changes, &(&1 + 1))}

    def handle_info({PhoenixKitWeb.Components.PeoplePicker, "pp", {:changed, keys}}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :keys, keys)}
  end

  defp open(conn, session \\ %{}), do: live_isolated(conn, Host, session: session)

  defp keys(view),
    do: view |> element("#parent-keys") |> render() |> Floki.parse_fragment!() |> Floki.text()

  defp focus(view), do: view |> element("#pp-q") |> render_focus()

  test "opening shows each group's first rows; a press adds, and the parent gets the list", %{
    conn: conn
  } do
    {:ok, view, _html} = open(conn)
    focus(view)

    assert has_element?(view, "#pp-group-team", "Kitchen")
    assert has_element?(view, "#pp-group-person", "Person 1")
    refute has_element?(view, "#pp-group-person", "Person 6")
    assert has_element?(view, "#pp-group-person-more")

    view |> element(~s([data-pick="person:p2"])) |> render_click()
    view |> element(~s([data-pick="team:t1"])) |> render_click()

    assert keys(view) == "person:p2,team:t1"
    assert has_element?(view, "#pp-chip-person-p2", "Person 2")
    assert has_element?(view, ~s(input[type="hidden"][name="thing[people][]"][value="team:t1"]))
  end

  test "× and a second press take a pick off", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    focus(view)
    view |> element(~s([data-pick="person:p2"])) |> render_click()
    view |> element(~s([data-pick="person:p3"])) |> render_click()

    view |> element("#pp-remove-person-p2") |> render_click()
    assert keys(view) == "person:p3"

    view |> element(~s([data-pick="person:p3"])) |> render_click()
    assert keys(view) == ""
  end

  test "adding from a browsed list keeps that list where it was", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    focus(view)
    view |> element("#pp-group-person-more") |> render_click()

    # The second page is loaded (scrolled down), then a person on it is added.
    view |> with_target("#pp") |> render_hook("more", %{})
    assert has_element?(view, ~s(#pp-options [data-pick="person:p12"]))

    view |> element(~s(#pp-options [data-pick="person:p9"])) |> render_click()

    # Still the browsed list, both pages, the pick ticked in place.
    assert has_element?(view, "#pp-back")
    assert has_element?(view, ~s(#pp-options [data-pick="person:p1"]))
    assert has_element?(view, ~s(#pp-options [data-pick="person:p12"]))
    assert has_element?(view, ~s(#pp-options [data-pick="person:p9"][aria-selected="true"]))
  end

  test "typing searches, and never reaches the surrounding form", %{conn: conn} do
    {:ok, view, html} = open(conn)
    assert html =~ ~s(form="pp-no-form")

    view |> element("#pp-q") |> render_keyup(%{"value" => "Kitch"})
    assert has_element?(view, ~s(#pp-options [data-pick="team:t1"]))
    refute has_element?(view, ~s(#pp-options [data-pick="person:p1"]))
    assert view |> element("#parent-changes") |> render() =~ ">0<"
  end

  test "a key the source cannot describe picks nothing", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    view |> with_target("#pp") |> render_click("toggle", %{"kind" => "person", "uuid" => "ghost"})
    assert keys(view) == ""
  end

  test "a source can ask first, and refuse with a line", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    view |> element("#pp-q") |> render_keyup(%{"value" => "Person 12"})
    view |> element(~s([data-pick="person:p12"])) |> render_click()

    assert has_element?(view, "#pp-confirm", "Person 12 has none.")
    assert keys(view) == ""

    view |> element("#pp-confirm-yes") |> render_click()
    assert keys(view) == "person:p11"
    refute has_element?(view, "#pp-confirm")

    view |> element("#pp-q") |> render_keyup(%{"value" => "Person 10"})
    view |> element(~s([data-pick="person:p10"])) |> render_click()
    assert has_element?(view, "#pp-notice", "Their record is in the trash.")
    assert keys(view) == "person:p11"
  end

  test "max 1 replaces the pick", %{conn: conn} do
    {:ok, view, _html} = open(conn, %{"max" => 1})
    focus(view)
    view |> element(~s([data-pick="person:p2"])) |> render_click()
    view |> element(~s([data-pick="person:p3"])) |> render_click()
    assert keys(view) == "person:p3"
  end

  test "Add me picks the viewer, and a chip carries its tags", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    view |> element("#pp-me") |> render_click()

    assert keys(view) == "person:p1"
    assert has_element?(view, "#pp-chip-person-p1 [data-tags]", "You")
    assert has_element?(view, "#pp-chip-person-p1 [data-tags] .badge-info", "Project owner")
    refute has_element?(view, "#pp-me")
  end

  describe "UserSource" do
    setup do
      {user, _} = create_admin_user()

      {:ok, user} =
        Auth.update_user_profile(user, %{"first_name" => "Zelda", "last_name" => "Quill"})

      %{user: user}
    end

    test "finds an account by name, labelled with its display name", %{user: user} do
      {rows, _next} = UserSource.page({:search, "Zelda Q"}, nil, 10, %{viewer_uuid: nil})
      assert [%{kind: "user", label: "Zelda Quill", user: %{uuid: uuid}}] = rows
      assert uuid == user.uuid
    end

    test "remembers a viewer's picks for Recent", %{user: user} do
      ctx = %{viewer_uuid: user.uuid}
      :ok = UserSource.remember({"user", user.uuid}, ctx)
      assert [%{uuid: uuid}] = UserSource.recent(5, ctx)
      assert uuid == user.uuid
    end

    test "describes only active accounts", %{user: user} do
      assert %{label: "Zelda Quill"} = UserSource.describe({"user", user.uuid}, %{})
      assert UserSource.describe({"user", "not-a-uuid"}, %{}) == nil
      assert UserSource.describe({"team", user.uuid}, %{}) == nil
    end
  end

  test "is exported for modules" do
    assert function_exported?(PeoplePicker, :render, 1)
  end
end
