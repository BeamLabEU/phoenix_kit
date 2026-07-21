defmodule PhoenixKitWeb.Components.Core.AdminPageHeaderTest do
  @moduledoc """
  Render tests for `<.admin_page_header>`. Pins:

  - `back` renders a working navigate link (previously a documented no-op)
  - `back_label` renders next to the arrow when given
  - icon-only back button still carries an accessible label when `back_label`
    is omitted
  - no `back` attr → no back link at all
  - title/subtitle still render as before
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.AdminPageHeader

  describe "admin_page_header/1" do
    test "back renders a navigate link to the given path" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header back="/phoenix_kit/admin/settings/email-sending" title="Send Profiles" />
        """)

      assert result =~ ~s(href="/phoenix_kit/admin/settings/email-sending")
      assert result =~ "hero-arrow-left"
    end

    test "back_label renders next to the arrow" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header back="/admin/x" back_label="Email Sending" title="Send Profiles" />
        """)

      assert result =~ "Email Sending"
    end

    test "icon-only back button (no back_label) still gets an accessible label" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header back="/admin/x" title="Send Profiles" />
        """)

      assert result =~ ~s(aria-label="Back")
    end

    test "icon-only back renders as an inline circle chip, not a standalone row" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header back="/admin/x" title="Send Profiles" />
        """)

      # The chip lives inside the title cluster (items-start) as a circle…
      assert result =~ "btn-circle"
      assert result =~ "items-start"
      # …and the back link precedes the h1 within the same flex row: the link
      # must open AFTER the title-row wrapper div, never before it (the old
      # anatomy rendered it as a standalone row above).
      {link_pos, _} = :binary.match(result, "hero-arrow-left")
      {row_pos, _} = :binary.match(result, "sm:justify-between")
      assert row_pos < link_pos
    end

    test "back_label switches the chip off circle mode and hides the label on phones" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header back="/admin/x" back_label="Email Sending" title="Send Profiles" />
        """)

      refute result =~ "btn-circle"
      assert result =~ "hidden sm:inline"
    end

    test "no back attr → no back link rendered" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header title="Send Profiles" />
        """)

      refute result =~ "hero-arrow-left"
    end

    test "title and subtitle still render" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.admin_page_header title="Send Profiles" subtitle="Manage send profiles" />
        """)

      assert result =~ "Send Profiles"
      assert result =~ "Manage send profiles"
    end
  end
end
