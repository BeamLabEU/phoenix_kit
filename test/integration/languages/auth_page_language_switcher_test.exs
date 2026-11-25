defmodule PhoenixKit.Integration.Languages.AuthPageLanguageSwitcherTest do
  @moduledoc """
  The language switcher under the auth forms follows the
  `auth_language_switcher_enabled` setting (Authorization settings, Login Page
  Branding tab): shown by default when the site serves 2+ languages, hidden
  when an admin switches it off, and an explicit `show_language_switcher`
  assign from a caller always wins.
  """

  use PhoenixKit.DataCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Components.AuthPageWrapper

  @switcher "#language-switcher-dropdown"

  defp render_wrapper(extra \\ %{}) do
    assigns =
      Map.merge(
        %{
          flash: %{},
          page_title: "Log in",
          inner_block: [%{inner_block: fn _, _ -> "SIGN IN FORM" end}]
        },
        extra
      )

    render_component(&AuthPageWrapper.auth_page_wrapper/1, assigns)
  end

  defp switcher?(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(@switcher) |> Enum.count() > 0

  defp set_switcher_setting(value) do
    {:ok, _} = Settings.update_setting("auth_language_switcher_enabled", value)
  end

  describe "with two enabled languages" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("ja")
      assert length(Languages.get_enabled_languages()) > 1
      :ok
    end

    test "the switcher is shown by default" do
      html = render_wrapper()

      assert html =~ "SIGN IN FORM"
      assert switcher?(html)
    end

    test "the setting on shows it" do
      set_switcher_setting("true")
      assert switcher?(render_wrapper())
    end

    test "the setting off hides it, the form stays" do
      set_switcher_setting("false")
      html = render_wrapper()

      assert html =~ "SIGN IN FORM"
      refute switcher?(html)
    end

    test "an explicit assign true wins over the setting off" do
      set_switcher_setting("false")
      assert switcher?(render_wrapper(%{show_language_switcher: true}))
    end

    test "an explicit assign false wins over the setting on" do
      set_switcher_setting("true")
      refute switcher?(render_wrapper(%{show_language_switcher: false}))
    end
  end

  describe "with the Languages module off" do
    test "no switcher whatever the setting says" do
      set_switcher_setting("true")
      refute switcher?(render_wrapper())
    end
  end

  test "the setting defaults to on" do
    assert Settings.get_defaults()["auth_language_switcher_enabled"] == "true"
  end
end
