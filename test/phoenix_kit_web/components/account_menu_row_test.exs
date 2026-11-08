defmodule PhoenixKitWeb.Components.AccountMenuRowTest do
  @moduledoc """
  The account rows of the avatar menus (admin and user dashboard) stay inside
  the menu. daisyUI's menu `li` is a wrapping column flex whose line takes its
  widest item's content width, so without `flex-nowrap` on the li and
  `w-full` on the row a long email pushed the active row's role badge and
  check past the menu's right edge (2026-11-02).

  Both menus render their rows through `AccountMenu.accounts_section/1`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.AccountMenu

  defp account(email, active?, root?),
    do: %{email: email, role: "User", ref: email, active?: active?, root?: root?}

  test "an account row's li does not wrap and the row takes its width" do
    assigns = %{
      scope: %Scope{},
      accounts: [
        account("a-very-long-address-for-a-narrow-menu@example.com", true, true),
        account("b@example.com", false, false)
      ]
    }

    html =
      rendered_to_string(~H"""
      <AccountMenu.accounts_section
        scope={@scope}
        accounts={@accounts}
        current_path="/admin"
        modal_id="m"
      />
      """)

    # Whitespace-tolerant: a re-indent of the template must not fail it.
    assert html =~
             ~r/<li class="p-0 min-w-0 flex-nowrap">\s*<div class="!p-0 flex w-full items-center gap-1 min-w-0/
  end

  for file <- ~w(admin_nav.ex user_dashboard_nav.ex) do
    test "#{file} renders its account rows through the shared section" do
      source = File.read!(Path.join("lib/phoenix_kit_web/components", unquote(file)))
      assert source =~ "AccountMenu.accounts_section"
      assert source =~ "AccountMenu.add_account_modal"
    end
  end
end
