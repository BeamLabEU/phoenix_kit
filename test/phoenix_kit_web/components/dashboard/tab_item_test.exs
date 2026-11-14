defmodule PhoenixKitWeb.Components.Dashboard.TabItemTest do
  @moduledoc """
  Render-integration tests for PhoenixKitWeb.Components.Dashboard.TabItem.

  Verifies that:
  - Tabs without a gettext_backend render raw labels (regression guard).
  - Tabs with gettext_backend render the translated label for the current locale.
  - Tooltips are rendered via localized_tooltip (title attr).
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitWeb.Components.Dashboard.TabItem

  @backend PhoenixKitWeb.Gettext
  @known_msgid "Dashboard"
  @known_ru_translation "Панель управления"

  setup do
    original_locale = Gettext.get_locale(@backend)

    on_exit(fn ->
      Gettext.put_locale(@backend, original_locale)
    end)

    :ok
  end

  describe "tab_item/1 — label rendering" do
    test "renders raw label when gettext_backend is nil (regression)" do
      tab = Tab.new!(id: :home, label: "Home", path: "/home", icon: "hero-home")

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil
        )

      assert html =~ "Home"
    end

    test "active tab carries aria-current=page; inactive does not" do
      # The AdminSidebarScroll JS (phoenix_kit_admin.js) locates the current
      # page's link via [aria-current="page"] to center it when no saved
      # scroll position exists — and it's the accessible marker anyway.
      tab = Tab.new!(id: :home, label: "Home", path: "/home", icon: "hero-home")

      active_html =
        render_component(&TabItem.tab_item/1, tab: tab, active: true, locale: nil)

      inactive_html =
        render_component(&TabItem.tab_item/1, tab: tab, active: false, locale: nil)

      assert active_html =~ ~s(aria-current="page")
      refute inactive_html =~ "aria-current"
    end

    test "renders translated label when gettext_backend is set and locale is ru" do
      Gettext.put_locale(@backend, "ru")

      tab =
        Tab.new!(
          id: :dashboard,
          label: @known_msgid,
          path: "/dashboard",
          icon: "hero-home",
          gettext_backend: @backend
        )

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil
        )

      assert html =~ @known_ru_translation
      refute html =~ @known_msgid
    end

    test "renders raw label when locale has no translation" do
      Gettext.put_locale(@backend, "en")

      tab =
        Tab.new!(
          id: :dashboard,
          label: @known_msgid,
          path: "/dashboard",
          icon: "hero-home",
          gettext_backend: @backend
        )

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil
        )

      assert html =~ @known_msgid
    end
  end

  describe "tab_item/1 — admin sidebar compact mode handles" do
    # Compact mode is CSS over a client-side `data-pk-sidebar` stamp, so the
    # server's whole contribution is this handle. A selector that stops
    # matching fails silently in the browser, which is exactly why it is
    # pinned here rather than left to the stylesheet.

    test "the label span carries pk-sidebar-label" do
      tab = Tab.new!(id: :home, label: "Home", path: "/home", icon: "hero-home")

      html = render_component(&TabItem.tab_item/1, tab: tab, active: false, locale: nil)

      assert html =~ "pk-sidebar-label"
      # Rendered, not removed: CSS hides it, so the link keeps its
      # accessible name while the sidebar is collapsed.
      assert html =~ "Home"
    end

    test "compact rendering still omits the label entirely" do
      # The `compact` ATTR is a different thing from the sidebar's compact
      # MODE: it removes the label server-side, for callers that never want
      # one. Unchanged by this feature.
      tab = Tab.new!(id: :home, label: "Home", path: "/home", icon: "hero-home")

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil,
          compact: true
        )

      refute html =~ "pk-sidebar-label"
    end
  end

  describe "tab_item/1 — tooltip rendering" do
    test "renders translated title attr when backend is set and locale is ru" do
      Gettext.put_locale(@backend, "ru")

      tab =
        Tab.new!(
          id: :dashboard,
          label: @known_msgid,
          path: "/dashboard",
          tooltip: @known_msgid,
          gettext_backend: @backend
        )

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil
        )

      assert html =~ ~s(title="#{@known_ru_translation}")
    end

    test "renders raw tooltip as title when gettext_backend is nil" do
      tab =
        Tab.new!(
          id: :settings,
          label: "Settings",
          path: "/settings",
          tooltip: "Open settings"
        )

      html =
        render_component(&TabItem.tab_item/1,
          tab: tab,
          active: false,
          locale: nil
        )

      assert html =~ ~s(title="Open settings")
    end
  end
end
