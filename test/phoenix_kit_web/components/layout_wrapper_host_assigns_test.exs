defmodule PhoenixKitWeb.Components.LayoutWrapperHostAssignsTest do
  @moduledoc """
  Pins what a host's `:app` layout (`config :phoenix_kit, layout:`) receives
  when a kit page renders through `LayoutWrapper.app_layout/1`.

  `app_layout/1` is a function component, so the host layout is handed
  `app_layout`'s own assigns — its declared attrs, the slots, `module_assigns`
  flattened, and the few compatibility keys `prepare_parent_layout_assigns/1`
  adds — never the calling page's assigns. A kit page's generic assign such as
  `:page` (pagination) therefore cannot collide with a host layout attr of the
  same name. These tests keep it that way: the exact key set is pinned, so a
  change that widens what hosts see has to update the list (and the
  "What a host layout receives" section of `guides/integration.md`) on purpose.

  The host **root** layout is different: Phoenix renders it with every
  assign of the LiveView (or conn), which the kit does not control. See the
  guide.

  DB-free: every setting the layout would read is passed in as an assign.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.LayoutWrapper
  alias PhoenixKitWeb.Test.PageAttrHostLayout

  # The assigns a host `:app` layout receives from a non-admin kit page. Keep in
  # sync with `guides/integration.md` → "What a host layout receives".
  @host_layout_keys MapSet.new([
                      :__changed__,
                      :__given__,
                      # slots and content
                      :inner_block,
                      :inner_content,
                      :action,
                      :toolbar,
                      # app_layout attrs
                      :flash,
                      :socket,
                      :phoenix_kit_current_scope,
                      :phoenix_kit_current_user,
                      :page_title,
                      :page_subtitle,
                      :page_section,
                      :page_section_path,
                      :page_crumbs,
                      :page_title_switcher,
                      :page_action,
                      :current_path,
                      :current_host,
                      :project_title,
                      :show_admin_panel_label,
                      :show_page_descriptions,
                      :dev_environment,
                      :current_locale,
                      :from_layout,
                      :pk_pending_invitations,
                      :admin_edit_url,
                      :admin_edit_label,
                      :module_assigns,
                      # added by app_layout before the host layout is applied
                      :content_language,
                      :crawlers_no_index,
                      # compatibility keys from prepare_parent_layout_assigns/1
                      :current_user,
                      :phoenix_kit_integrated,
                      :phoenix_kit_version,
                      :phoenix_version_info
                    ])

  setup do
    saved =
      for key <- [:phoenix_version_strategy, :layout],
          do: {key, Application.fetch_env(:phoenix_kit, key)}

    Application.put_env(:phoenix_kit, :phoenix_version_strategy, :modern)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:phoenix_kit, key, v)
          :error -> Application.delete_env(:phoenix_kit, key)
        end
      end
    end)

    :ok
  end

  # A kit page whose own assigns carry `:page` (a pagination number) and other
  # generic names, rendering through app_layout the way every kit page does.
  defp render_kit_page(module_assigns \\ %{}) do
    assigns = %{
      __changed__: nil,
      page: 3,
      page_size: 25,
      form: :not_for_the_host,
      flash: %{},
      module_assigns: module_assigns
    }

    ~H"""
    <LayoutWrapper.app_layout
      flash={@flash}
      current_path="/profile/settings"
      page_title="Kit page"
      current_locale="en"
      module_assigns={@module_assigns}
    >
      <span id="kit-body">page {@page}</span>
    </LayoutWrapper.app_layout>
    """
    |> rendered_to_string()
  end

  test "a host layout declaring `attr :page` renders a kit page whose own :page is an integer" do
    Application.put_env(:phoenix_kit, :layout, {PageAttrHostLayout, :app})

    html = render_kit_page()

    assert html =~ ~s(id="host-shell")
    # The host's own default, not the kit page's 3.
    assert html =~ ~s(data-host-page="home")
    assert html =~ ~s(<span id="kit-body">page 3</span>)
  end

  test "the host layout receives exactly the documented assigns, never the page's own" do
    Application.put_env(:phoenix_kit, :layout, {PageAttrHostLayout, :capture})

    render_kit_page()

    assert_received {:host_layout_assigns, received}

    for key <- [:page, :page_size, :form], do: refute(Map.has_key?(received, key))

    assert MapSet.new(Map.keys(received)) == @host_layout_keys

    assert received.page_title == "Kit page"
    assert received.current_path == "/profile/settings"
    assert received.current_locale == "en"
    assert received.flash == %{}
    assert received.phoenix_kit_integrated == true
    assert Map.has_key?(received, :current_user)
  end

  test "module_assigns keys still reach the host layout as top-level assigns" do
    Application.put_env(:phoenix_kit, :layout, {PageAttrHostLayout, :capture})

    render_kit_page(%{phoenix_kit_publishing_translations: [%{code: "et"}], og: %{title: "T"}})

    assert_received {:host_layout_assigns, received}
    assert received.phoenix_kit_publishing_translations == [%{code: "et"}]
    assert received.og == %{title: "T"}

    assert MapSet.new(Map.keys(received)) ==
             MapSet.union(
               @host_layout_keys,
               MapSet.new([:phoenix_kit_publishing_translations, :og])
             )
  end

  test "a module_assigns key never overrides a kit-managed assign" do
    Application.put_env(:phoenix_kit, :layout, {PageAttrHostLayout, :capture})

    render_kit_page(%{page_title: "hijacked", flash: %{"error" => "x"}})

    assert_received {:host_layout_assigns, received}
    assert received.page_title == "Kit page"
    assert received.flash == %{}
  end
end
