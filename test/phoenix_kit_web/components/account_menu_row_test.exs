defmodule PhoenixKitWeb.Components.AccountMenuRowTest do
  @moduledoc """
  The account rows of the avatar menus (admin and user dashboard) stay inside
  the menu. daisyUI's menu `li` is a wrapping column flex whose line takes its
  widest item's content width, so without `flex-nowrap` on the li and
  `w-full` on the row a long email pushed the active row's role badge and
  check past the menu's right edge (2026-11-02). The rows need a session and
  a multi-account setup to render, so the markup is checked in the source.
  """
  use ExUnit.Case, async: true

  for file <- ~w(admin_nav.ex user_dashboard_nav.ex) do
    test "#{file}: the account row's li does not wrap and the row takes its width" do
      source = File.read!(Path.join("lib/phoenix_kit_web/components", unquote(file)))

      # Whitespace-tolerant: a re-indent of the template must not fail it.
      assert source =~
               ~r/<li class="p-0 min-w-0 flex-nowrap">\s*<div class="!p-0 flex w-full items-center gap-1 min-w-0/
    end
  end
end
