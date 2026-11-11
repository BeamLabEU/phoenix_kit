defmodule PhoenixKitWeb.Components.Core.NavTabsTest do
  @moduledoc """
  `nav_tabs/1` is the ecosystem's tab component, and until now most tab strips
  in the module libraries reimplemented it instead of calling it — which is why
  a single daisyUI class rename (`tabs-boxed` -> `tabs-box` in v5) had to be
  applied at 21 hand-rolled sites across 8 repositories.

  Two things blocked adoption, and these tests pin both fixes:

  - a query-param tab strip needs `patch` (a `navigate` remounts the LiveView
    and drops socket state), and the component only ever emitted `navigate`;
  - the container's `bg-base-200 p-1` was baked in, and `class` can only ADD,
    so a strip nested in an already-framed container had no way to shed it.

  Plus the failure mode that makes silent breakage possible at all: the tab
  LINK KEYS live in a runtime map, so no `attr` declaration can validate them.
  A module passing `:patch` to an older core would land in the button branch
  with `on_change` nil and render a strip wired to `phx-click={nil}` — right
  down to the styling. Two link keys on one tab raise; a missing link with
  no `on_change` logs a warning rather than taking the LiveView down.

  The second adoption wave pins two more contracts the module migrations
  depend on: `variant={:border}` is daisyUI's underline look, and
  `:navigate`/`:patch` pass through verbatim (like `Phoenix.Component.link/1`)
  while legacy `:path` still goes through `Routes.path/1`. Those two prefix
  rules are not interchangeable spellings — swapping the keys while keeping
  the same value either under-prefixes or double-prefixes.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.NavTabs

  defp render_tabs(assigns) do
    assigns = Map.put_new(assigns, :active_tab, "a")
    render_component(&NavTabs.nav_tabs/1, assigns)
  end

  describe "link modes" do
    test ":patch renders a patch link, not a navigate one" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "followers", label: "Followers", patch: "/profile/connections?tab=followers"}
          ]
        })

      # data-phx-link=patch is what keeps the click inside the current
      # LiveView; navigate would remount it and lose the socket state.
      assert html =~ ~s(data-phx-link="patch")
      refute html =~ ~s(data-phx-link="redirect")
    end

    test ":navigate renders a navigation link" do
      html = render_tabs(%{tabs: [%{id: "a", label: "General", navigate: "/admin/settings"}]})

      assert html =~ ~s(data-phx-link="redirect")
      refute html =~ ~s(data-phx-link="patch")
    end

    test ":path still means navigate AND still gets the route-helper treatment" do
      raw = "/admin/settings"
      expected = Routes.path(raw)
      # The pin is "helper ran", not "substring of the raw path survived".
      # `=~ "/admin/settings"` would pass for an unprefixed href too.
      assert expected != raw

      from_path = render_tabs(%{tabs: [%{id: "a", label: "General", path: raw}]})

      assert from_path =~ ~s(data-phx-link="redirect")
      assert from_path =~ ~s(href="#{expected}")
    end

    test ":navigate and :path are the same link kind with different prefix rules" do
      raw = "/admin/settings"
      from_path = render_tabs(%{tabs: [%{id: "a", label: "A", path: raw}]})
      from_navigate = render_tabs(%{tabs: [%{id: "a", label: "A", navigate: raw}]})

      assert from_path =~ ~s(data-phx-link="redirect")
      assert from_navigate =~ ~s(data-phx-link="redirect")
      refute from_path == from_navigate
      assert from_navigate =~ ~s(href="#{raw}")
      assert from_path =~ ~s(href="#{Routes.path(raw)}")
    end

    test ":navigate and :patch pass through verbatim — no helper, no double-prefix" do
      # Modules build tab URLs with their own Paths helpers, which already
      # apply the URL prefix and locale. Running them through Routes.path/1
      # again double-prefixes; only legacy :path gets the helper.
      unprefixed = "/admin/crm/contacts/x?tab=files"
      helper = Routes.path(unprefixed)
      assert helper != unprefixed

      html = render_tabs(%{tabs: [%{id: "a", label: "A", patch: unprefixed}]})

      assert html =~ ~s(href="#{unprefixed}")
      refute html =~ ~s(href="#{helper}")

      already_prefixed = "/phoenix_kit/en/admin/crm/contacts/x?tab=files"

      html =
        render_tabs(%{
          tabs: [%{id: "a", label: "A", navigate: already_prefixed}]
        })

      assert html =~ ~s(href="#{already_prefixed}")
    end

    test "a query string on :path survives the route helper intact" do
      raw = "/profile/connections?tab=followers"
      html = render_tabs(%{tabs: [%{id: "followers", label: "Followers", path: raw}]})

      # If the helper dropped or re-encoded the query, the tab would render
      # but the active state would never stick on reload.
      assert html =~ "?tab=followers"
      assert html =~ Routes.path(raw)
    end

    test "a query string on a verbatim :patch survives intact" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "followers", label: "Followers", patch: "/profile/connections?tab=followers"}
          ]
        })

      assert html =~ ~s(href="/profile/connections?tab=followers")
    end

    test "a strip may mix link tabs and event tabs" do
      html =
        render_tabs(%{
          on_change: "switch",
          tabs: [
            %{id: "a", label: "Linked", navigate: "/admin/settings"},
            %{id: "b", label: "Evented"}
          ]
        })

      assert html =~ ~s(data-phx-link="redirect")
      assert html =~ ~s(phx-value-tab="b")
    end
  end

  describe "event payload" do
    test "event tabs dispatch phx-value-tab, never phx-value-value" do
      html = render_tabs(%{on_change: "switch_tab", tabs: [%{id: "oban", label: "Oban"}]})

      assert html =~ ~s(phx-value-tab="oban")

      # `value` is the hazardous key: LiveView's extractMeta overwrites
      # meta.value with the element's own .value DOM property, so a <button>
      # would deliver "". The component must never emit it.
      refute html =~ "phx-value-value"
    end
  end

  describe "variants" do
    test ":boxed is the default and keeps the filled strip" do
      html = render_tabs(%{on_change: "s", tabs: [%{id: "a", label: "A"}]})

      assert html =~ "bg-base-200"
      assert html =~ "tabs-box"
    end

    test ":plain drops the frame a caller could not otherwise remove" do
      html = render_tabs(%{variant: :plain, on_change: "s", tabs: [%{id: "a", label: "A"}]})

      refute html =~ "bg-base-200"

      # `tabs-box` must go too: it IS the daisyUI frame (background, padding,
      # radius, shadow), so dropping only the bg-base-200/p-1 overrides would
      # leave the box drawn and make :plain a lie.
      refute html =~ "tabs-box"

      # Still a tab strip, just unframed.
      assert html =~ "tabs"
    end

    test ":border is the underline family — no box, no frame overrides" do
      html = render_tabs(%{variant: :border, on_change: "s", tabs: [%{id: "a", label: "A"}]})

      assert html =~ "tabs-border"
      refute html =~ "tabs-box"
      refute html =~ "bg-base-200"
    end

    test "adding :border changed nothing about :boxed or :plain" do
      boxed = render_tabs(%{on_change: "s", tabs: [%{id: "a", label: "A"}]})
      plain = render_tabs(%{variant: :plain, on_change: "s", tabs: [%{id: "a", label: "A"}]})

      assert boxed =~ "tabs tabs-box bg-base-200 p-1"
      assert plain =~ ~s(class="tabs")
      refute plain =~ "tabs-border"
    end

    test "class ADDS to the container rather than replacing it" do
      html =
        render_tabs(%{
          variant: :plain,
          class: "inline-flex",
          on_change: "s",
          tabs: [%{id: "a", label: "A"}]
        })

      # Appended to the variant's classes, not swapped for them.
      assert html =~ "inline-flex"
      assert html =~ "tabs"
    end
  end

  describe "malformed tabs" do
    test "a tab with no link key and no on_change warns but still renders" do
      # Deliberately NOT a raise. This is a library: a dead tab is bad, but
      # taking the whole LiveView down over a tab strip is worse, and we
      # cannot audit every consumer. It has to stay findable, though.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = render_tabs(%{tabs: [%{id: "a", label: "A"}]})
          assert html =~ "<button"
        end)

      assert log =~ "renders a button that does nothing"
    end

    test "setting more than one link key raises" do
      # No degraded render is defensible here — there is no way to choose —
      # and :navigate/:patch are new enough that no existing caller can trip it.
      for tab <- [
            %{id: "a", label: "A", navigate: "/x", patch: "/y"},
            %{id: "a", label: "A", navigate: "/x", path: "/y"},
            %{id: "a", label: "A", patch: "/x", path: "/y"}
          ] do
        assert_raise ArgumentError, ~r/more than one link key/, fn ->
          render_tabs(%{tabs: [tab]})
        end
      end
    end

    test "a nil link value counts as absent, not as a link to nowhere" do
      # Tab lists are routinely built with a conditional path; treating that
      # nil as a link hands Routes.path/1 a nil and raises mid-render.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = render_tabs(%{on_change: "s", tabs: [%{id: "a", label: "A", path: nil}]})

          assert html =~ ~s(phx-value-tab="a")
          refute html =~ "data-phx-link"
        end)

      # It fell back to the event tab cleanly, so nothing to warn about.
      refute log =~ "does nothing"
    end
  end

  describe "class helpers" do
    test "tablist_class/2 is what the component itself renders" do
      # Shared so tab-styled markup that is NOT a tab strip can reuse one
      # definition — the next daisyUI rename should be a change here, not a
      # sweep across every call site.
      assert NavTabs.tablist_class(:boxed) == ["tabs tabs-box bg-base-200 p-1", nil]
      assert NavTabs.tablist_class(:plain) == ["tabs", nil]
      assert NavTabs.tablist_class(:plain, "inline-flex") == ["tabs", "inline-flex"]
      assert NavTabs.tablist_class(:border) == ["tabs tabs-border", nil]
      assert NavTabs.tablist_class(:border, "mb-4") == ["tabs tabs-border", "mb-4"]
    end

    test "an unknown variant fails loud, not as a silently unstyled strip" do
      assert_raise FunctionClauseError, fn -> NavTabs.tablist_class(:bogus) end
    end

    test "tab_class/2 marks the active tab" do
      assert NavTabs.tab_class(true) == ["tab gap-2", "tab-active", nil]
      assert NavTabs.tab_class(false) == ["tab gap-2", false, nil]
    end
  end

  describe "badges" do
    test "a nil badge renders nothing, not an empty badge" do
      # `badge: if(count > 0, do: count)` is the normal way to write a count
      # that only shows when non-zero; keying on key PRESENCE rendered that
      # as an empty pill.
      html = render_tabs(%{tabs: [%{id: "a", label: "Requests", navigate: "/x", badge: nil}]})

      assert html =~ "Requests"
      refute html =~ "badge"
    end

    test "a zero badge still renders — only nil is absent" do
      html = render_tabs(%{tabs: [%{id: "a", label: "Requests", navigate: "/x", badge: 0}]})

      assert html =~ "badge"
    end

    test "badge_class wins over the active-tab default" do
      # A pending-requests count stays badge-warning whether or not its tab
      # is the active one.
      html =
        render_tabs(%{
          active_tab: "a",
          tabs: [
            %{id: "a", label: "Requests", navigate: "/x", badge: 3, badge_class: "badge-warning"}
          ]
        })

      assert html =~ "badge-warning"
      refute html =~ "badge-primary"
    end

    test "without badge_class the active tab still gets the primary tone" do
      html =
        render_tabs(%{active_tab: "a", tabs: [%{id: "a", label: "A", navigate: "/x", badge: 3}]})

      assert html =~ "badge-primary"
    end
  end

  describe "icons and badges" do
    test "both render, in either mode" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "a", label: "Followers", navigate: "/x", icon: "hero-user", badge: 12}
          ]
        })

      assert html =~ "hero-user"
      assert html =~ "badge"
      assert html =~ "12"
    end
  end

  describe "trailing slot" do
    import Phoenix.Component, only: [sigil_H: 2]
    import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]

    test "renders controls inside the strip's frame and stretches the strip" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.nav_tabs active_tab="a" on_change="pick" tabs={[%{id: "a", label: "A"}, %{id: "b", label: "B"}]}>
          <:trailing>
            <select name="sort"><option>Manual</option></select>
          </:trailing>
        </.nav_tabs>
        """)

      # One frame holds tabs and control: the select is INSIDE the tablist.
      [tablist] = Regex.run(~r/<div role="tablist".*<\/div>\s*<\/div>/s, html)
      assert tablist =~ ~s(<select name="sort">)
      assert tablist =~ "flex-1"
      assert tablist =~ "ml-auto"
    end

    test "without it nothing changes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.nav_tabs active_tab="a" on_change="pick" tabs={[%{id: "a", label: "A"}]} />
        """)

      refute html =~ "flex-1"
      refute html =~ "ml-auto"
    end
  end

  describe "overflow: :wrap (default)" do
    @fixtures Path.expand("../../../fixtures/nav_tabs", __DIR__)

    # Captured from the component BEFORE overflow existed. Whitespace included:
    # every existing caller must keep rendering byte-identical markup.
    @link_set %{
      active_tab: "a",
      variant: :border,
      class: "tabs-sm mb-4",
      tabs: [
        %{id: "a", label: "General", icon: "hero-cog-6-tooth", navigate: "/admin/settings"},
        %{id: "b", label: "Followers", patch: "/p?tab=f", badge: 3, badge_class: "badge-warning"},
        %{id: "c", label: "Legacy", path: "/admin/x", badge: 0}
      ]
    }
    @event_set %{
      active_tab: "y",
      on_change: "switch",
      target: "#cmp",
      tabs: [
        %{id: "x", label: "Oban"},
        %{id: "y", label: "Sched", icon: "hero-clock", badge: 12}
      ]
    }

    test "link tabs render exactly as before" do
      expected = File.read!(Path.join(@fixtures, "link_wrap.html"))

      assert render_tabs(@link_set) == expected
      assert render_tabs(Map.put(@link_set, :overflow, :wrap)) == expected
    end

    test "event tabs render exactly as before" do
      expected = File.read!(Path.join(@fixtures, "event_wrap.html"))

      assert render_tabs(@event_set) == expected
      assert render_tabs(Map.put(@event_set, :overflow, :wrap)) == expected
    end

    test "carries no overflow markup" do
      html = render_tabs(@link_set)

      refute html =~ "phx-hook"
      refute html =~ "data-nav"
      refute html =~ "More tabs"
    end
  end

  describe "overflow: :menu" do
    @tabs [
      %{id: "a", label: "General", icon: "hero-cog-6-tooth", navigate: "/admin/settings"},
      %{id: "b", label: "Followers", patch: "/p?tab=f", badge: 3},
      %{id: "c", label: "Legacy", path: "/admin/x", badge: 0, badge_class: "badge-warning"}
    ]

    defp menu_tabs(assigns) do
      html = render_tabs(Map.put(assigns, :overflow, :menu))
      [before_menu, menu] = String.split(html, "data-nav-menu", parts: 2)
      {html, before_menu, menu}
    end

    test "renders the hook on a wrapper with an id, around a strip that keeps the tab roles" do
      {html, strip, _menu} = menu_tabs(%{tabs: @tabs})

      assert html =~ ~s(phx-hook="NavTabsOverflow")
      assert html =~ ~r/id="nav-tabs-\d+"/
      assert strip =~ ~s(role="tablist")
      assert strip =~ "data-nav-strip"
      assert length(Regex.scan(~r/role="tab"/, strip)) == 3
      assert html =~ ~s(role="menu")
      assert length(Regex.scan(~r/role="menuitem"/, html)) == 3
    end

    test "the id is stable across renders and overridable" do
      {first, _, _} = menu_tabs(%{tabs: @tabs})
      {second, _, _} = menu_tabs(%{tabs: @tabs})
      {custom, _, _} = menu_tabs(%{tabs: @tabs, id: "order-tabs"})

      [id] = Regex.run(~r/id="nav-tabs-\d+"/, first)
      assert second =~ id
      assert custom =~ ~s(id="order-tabs")
      assert custom =~ ~s(id="order-tabs-menu")
      assert custom =~ ~s(aria-controls="order-tabs-menu")
    end

    test "the more button starts hidden and is labelled for assistive tech" do
      {_html, strip, _menu} = menu_tabs(%{tabs: @tabs})

      [button] = Regex.run(~r/<button[^>]*data-nav-more[^>]*>/s, strip)
      assert button =~ ~r/class="[^"]*\bhidden\b/
      assert button =~ ~s(aria-label="More tabs")
      assert button =~ ~s(aria-haspopup="menu")
      assert button =~ ~s(aria-expanded="false")
      # Not a tab: the roving tab strip must not count it.
      refute button =~ ~s(role="tab")
      assert strip =~ "hero-ellipsis-horizontal"
    end

    test "menu items mirror each tab's link attributes, in order" do
      {html, strip, menu} = menu_tabs(%{tabs: @tabs})

      for chunk <- [strip, menu] do
        assert chunk =~ ~s(href="/admin/settings")
        assert chunk =~ ~s(data-phx-link="redirect")
        assert chunk =~ ~s(href="/p?tab=f")
        assert chunk =~ ~s(data-phx-link="patch")
        assert chunk =~ ~s(href="#{Routes.path("/admin/x")}")
      end

      ids = Regex.scan(~r/data-nav-item="(\w+)"/, html, capture: :all_but_first)
      assert ids == [["a"], ["b"], ["c"]]
    end

    test "event tabs get the same phx-click / phx-target / phx-value-tab in the menu" do
      {_html, strip, menu} =
        menu_tabs(%{
          on_change: "switch",
          target: "#cmp",
          tabs: [%{id: "x", label: "Oban"}, %{id: "y", label: "Sched"}]
        })

      for chunk <- [strip, menu], id <- ["x", "y"] do
        assert chunk =~ ~s(phx-click="switch")
        assert chunk =~ ~s(phx-target="#cmp")
        assert chunk =~ ~s(phx-value-tab="#{id}")
      end

      assert menu =~ ~s(role="menuitem")
      refute menu =~ ~s(role="tab")
    end

    test "a strip may mix link and event tabs" do
      {_html, strip, menu} =
        menu_tabs(%{
          on_change: "switch",
          tabs: [
            %{id: "a", label: "Linked", navigate: "/admin/settings"},
            %{id: "b", label: "Evented"}
          ]
        })

      for chunk <- [strip, menu] do
        assert chunk =~ ~s(data-phx-link="redirect")
        assert chunk =~ ~s(phx-value-tab="b")
      end
    end

    test "the active tab is marked in the strip and in the menu, and only it" do
      {_html, strip, menu} = menu_tabs(%{active_tab: "b", tabs: @tabs})

      assert length(Regex.scan(~r/data-nav-active/, strip)) == 1
      assert [tab] = Regex.run(~r/<a[^>]*data-nav-active[^>]*>/s, strip)
      assert tab =~ ~s(data-nav-tab="b")
      assert tab =~ "tab-active"

      assert length(Regex.scan(~r/aria-current="true"/, menu)) == 1
      assert [item] = Regex.run(~r/<a[^>]*aria-current[^>]*>/s, menu)
      assert item =~ ~s(data-nav-item="b")
    end

    test "icons and badges appear in the menu items too" do
      {_html, strip, menu} = menu_tabs(%{tabs: @tabs})

      for chunk <- [strip, menu] do
        assert chunk =~ "hero-cog-6-tooth"
        assert chunk =~ "General"
        assert chunk =~ ~r/badge[^>]*>\s*3\s*</
        assert chunk =~ ~r/badge-warning[^>]*>\s*0\s*</
      end
    end

    test "menu items are 44px touch targets" do
      {_html, _strip, menu} = menu_tabs(%{tabs: @tabs})

      assert menu =~ "min-h-11"
    end

    test "works with every variant, with tabs-sm through class, and nowrap" do
      for {variant, marker} <- [boxed: "tabs-box", plain: nil, border: "tabs-border"] do
        {html, _, _} = menu_tabs(%{variant: variant, class: "tabs-sm mb-4", tabs: @tabs})

        [wrapper] = Regex.run(~r/<div[^>]*phx-hook[^>]*>/s, html)
        assert wrapper =~ "tabs-sm mb-4"
        assert wrapper =~ "flex-nowrap"
        if marker, do: assert(wrapper =~ marker)
        if variant != :boxed, do: refute(wrapper =~ "tabs-box")
      end
    end

    test "the trailing slot stays last: strip, then the more button, then trailing, then the menu" do
      import Phoenix.Component, only: [sigil_H: 2]
      import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.nav_tabs
          active_tab="a"
          overflow={:menu}
          on_change="pick"
          tabs={[%{id: "a", label: "A"}, %{id: "b", label: "B"}]}
        >
          <:trailing>
            <select name="sort"><option>Manual</option></select>
          </:trailing>
        </.nav_tabs>
        """)

      pos = fn needle -> elem(:binary.match(html, needle), 0) end

      assert pos.("data-nav-strip") < pos.("data-nav-more")
      assert pos.("data-nav-more") < pos.(~s(<select name="sort">))
      assert pos.(~s(<select name="sort">)) < pos.("data-nav-menu")
      assert [wrapper] = Regex.run(~r/<div[^>]*phx-hook[^>]*>/s, html)
      assert wrapper =~ "flex-1"
    end

    test "without trailing the wrapper does not stretch" do
      {html, _, _} = menu_tabs(%{tabs: @tabs})
      [wrapper] = Regex.run(~r/<div[^>]*phx-hook[^>]*>/s, html)

      refute wrapper =~ "flex-1"
    end

    test "the menu is outside the clipped strip" do
      {_html, strip, _menu} = menu_tabs(%{tabs: @tabs})

      # `overflow-hidden` is on the strip only; the menu must not live inside it.
      [strip_open] = Regex.run(~r/<div[^>]*data-nav-strip[^>]*>/s, strip)
      assert strip_open =~ "overflow-hidden"
      [inside_strip, _rest] = String.split(strip, "data-nav-more", parts: 2)
      refute inside_strip =~ ~s(role="menu")
    end
  end
end
