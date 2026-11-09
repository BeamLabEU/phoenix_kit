defmodule PhoenixKitWeb.Integration.Users.UsersTableLayoutTest do
  @moduledoc """
  How the Users table reads: the account column names a company by its name,
  Full Name is for people, the avatar is a column of its own, a custom field
  can have a short column name, dates do not wrap, a narrow table drops
  columns in a set order, and a boolean custom field can filter the list
  through the URL.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.{Auth, CustomFields, TableColumns}
  alias PhoenixKit.Utils.Routes

  defp marker, do: "lay#{System.unique_integer([:positive])}"

  defp open(conn, user, query \\ ""),
    do: live(log_in_user(conn, user), Routes.path("/admin/users") <> query)

  defp doc(view), do: view |> render() |> Floki.parse_document!()

  defp header_texts(doc) do
    doc |> Floki.find("table thead th") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  defp header(doc, text) do
    doc |> Floki.find("table thead th") |> Enum.find(&(String.trim(Floki.text(&1)) == text))
  end

  defp row(doc, text) do
    doc |> Floki.find("table tbody tr") |> Enum.find(&(Floki.text(&1) =~ text))
  end

  # The cell under `header` in the row that mentions `text`.
  defp cell(doc, text, header) do
    index = Enum.find_index(header_texts(doc), &(&1 == header))
    doc |> row(text) |> Floki.find("td") |> Enum.at(index)
  end

  defp squish(node), do: node |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ")

  defp row_link_label(doc, text) do
    doc |> row(text) |> Floki.find("a span.sr-only") |> Floki.text() |> String.trim()
  end

  defp listed_emails(opts) do
    opts
    |> AuthCtx.list_users_paginated()
    |> Map.fetch!(:users)
    |> Enum.map(& &1.email)
    |> Enum.sort()
  end

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    on_exit(fn -> Settings.update_setting("enable_organization_accounts", "false") end)
    {admin, _} = create_admin_user()
    %{admin: admin}
  end

  describe "the account column" do
    test "a company shows its name over its email; a person shows their email", %{
      conn: conn,
      admin: admin
    } do
      m = marker()

      F.person(%{
        email: "#{m}-indie@example.com",
        account_type: "organization",
        organization_name: "#{m} Amwood OU"
      })

      F.person(%{email: "#{m}-ann@example.com"})

      F.person(%{
        email: "#{m}-denis@example.com",
        first_name: "Denis",
        last_name: "Sivovol",
        username: "#{m}_denis"
      })

      {:ok, view, _html} = open(conn, admin, "?q=#{m}")
      doc = doc(view)

      assert "Account" in header_texts(doc)
      refute "Email" in header_texts(doc)

      assert squish(cell(doc, "#{m} Amwood OU", "Account")) =~
               ~r/^#{m} Amwood OU Org #{m}-indie@example\.com/

      assert squish(cell(doc, "#{m}-ann@", "Account")) =~ ~r/^#{m}-ann@example\.com/
      assert row_link_label(doc, "#{m} Amwood OU") == "#{m} Amwood OU"
      assert row_link_label(doc, "#{m}-ann@") == "#{m}-ann@example.com"

      # A person with a name: the name, the email, the username, once each.
      assert squish(cell(doc, "#{m}-denis@", "Account")) ==
               "Denis Sivovol #{m}-denis@example.com @#{m}_denis"

      assert row_link_label(doc, "#{m}-denis@") == "Denis Sivovol"
    end

    test "a managed company without a contact email shows its name, not a blank", %{
      conn: conn,
      admin: admin
    } do
      m = marker()
      F.organization(%{organization_name: "#{m} Quiet Co", contact_email: nil})

      {:ok, view, _html} = open(conn, admin, "?q=#{m}")
      doc = doc(view)

      account = cell(doc, "#{m} Quiet Co", "Account")
      assert [{"span", _, _} = name | _] = Floki.find(account, "span.font-medium")
      assert String.trim(Floki.text(name)) == "#{m} Quiet Co"
      assert row_link_label(doc, "#{m} Quiet Co") == "#{m} Quiet Co"

      assert [badge] = Floki.find(account, "span.badge-secondary")
      assert String.trim(Floki.text(badge)) == "Managed"
      assert Floki.attribute(badge, "title") == ["Managed organization"]
    end

    test "the card view and the roles dialog name the company too", %{conn: conn, admin: admin} do
      m = marker()
      org = F.organization(%{organization_name: "#{m} Quiet Co", contact_email: nil})

      {:ok, view, _html} = open(conn, admin, "?q=#{m}")
      html = render_click(view, "show_role_management", %{"user_uuid" => org.uuid})
      assert html =~ "Manage Roles for #{m} Quiet Co"

      render_click(view, "hide_role_management", %{})
      html = render_click(view, "set_view_mode", %{"mode" => "card"})
      assert html =~ ~r/font-medium text-sm truncate min-w-0">#{m} Quiet Co</
    end
  end

  test "Full Name is for people, and holds the name alone", %{
    conn: conn,
    admin: admin
  } do
    m = marker()

    company =
      F.person(%{
        email: "#{m}-birch@example.com",
        account_type: "organization",
        organization_name: "#{m} Birch AS"
      })

    F.person(%{
      email: "#{m}-ann@example.com",
      first_name: "Ann",
      last_name: "Lee",
      organization_uuid: company.uuid
    })

    {:ok, view, _html} = open(conn, admin, "?q=#{m}")
    doc = doc(view)

    assert squish(cell(doc, "#{m}-birch@", "Full Name")) == "-"
    assert squish(cell(doc, "#{m}-ann@", "Full Name")) == "Ann Lee"
  end

  describe "the Organizations column" do
    defp org_cell(doc, text), do: cell(doc, text, "Organizations")

    test "lists a person's companies, both kinds, as plain text (a click opens the person)", %{
      conn: conn,
      admin: admin
    } do
      m = marker()
      birch = F.organization(%{organization_name: "#{m} Birch AS", managed_by_members: false})
      person = F.person(%{email: "#{m}-ann@example.com", organization_uuid: birch.uuid})
      oak = F.organization(%{organization_name: "#{m} Oak Trading"})
      F.manager(oak, person)
      F.person(%{email: "#{m}-solo@example.com"})

      {:ok, view, _html} = open(conn, admin, "?q=#{m}")
      doc = doc(view)

      assert "Organizations" in header_texts(doc)
      assert squish(org_cell(doc, "#{m}-ann@")) == "#{m} Birch AS #{m} Oak Trading"

      cell = org_cell(doc, "#{m}-ann@")
      assert [_] = Floki.find(cell, "span#user-#{person.uuid}-org-#{oak.uuid}")
      assert Floki.find(cell, "a") == []
      assert squish(org_cell(doc, "#{m}-solo@")) == "-"
    end

    test "shows three, or two and how many more", %{
      conn: conn,
      admin: admin
    } do
      m = marker()
      three = F.person(%{email: "#{m}-three@example.com"})
      five = F.person(%{email: "#{m}-five@example.com"})

      for n <- 1..5 do
        org = F.organization(%{organization_name: "#{m} Co #{n}"})
        F.manager(org, five)
        if n <= 3, do: F.manager(org, three)
      end

      {:ok, view, _html} = open(conn, admin, "?q=#{m}")
      doc = doc(view)

      assert squish(org_cell(doc, "#{m}-three@")) == "#{m} Co 1 #{m} Co 2 #{m} Co 3"
      assert squish(org_cell(doc, "#{m}-five@")) == "#{m} Co 1 #{m} Co 2 +3 more"

      assert doc
             |> org_cell("#{m}-five@")
             |> Floki.find("span#user-#{five.uuid}-orgs-more")
             |> squish() ==
               "+3 more"

      html = render_click(view, "set_view_mode", %{"mode" => "card"})
      assert html =~ "#{m} Co 1, #{m} Co 2 +3 more"
    end

    test "is not offered while organization accounts are off", %{conn: conn, admin: admin} do
      Settings.update_setting("enable_organization_accounts", "false")

      refute "organizations" in Enum.map(TableColumns.columns_spec().columns, & &1.id)
      refute "organizations" in TableColumns.get_default_columns()

      {:ok, view, _html} = open(conn, admin)
      refute "Organizations" in header_texts(doc(view))
    end
  end

  test "the avatar is a column of its own, on by default, and hiding it removes it", %{
    conn: conn,
    admin: admin
  } do
    spec = TableColumns.columns_spec()
    assert "avatar" in Enum.map(spec.columns, & &1.id)
    assert ["avatar" | _] = spec.defaults

    m = marker()
    F.person(%{email: "#{m}-ann@example.com"})
    {:ok, view, _html} = open(conn, admin, "?q=#{m}")
    doc = doc(view)

    assert [first | _] = Floki.find(doc, "table thead th")
    assert Floki.find(first, "span.sr-only") |> Floki.text() == "Avatar"
    assert [_] = doc |> row("#{m}-ann@") |> Floki.find(".avatar")
    assert [] = doc |> cell("#{m}-ann@", "Account") |> Floki.find(".avatar")

    view |> element(~s(button[phx-click="show_column_modal"])) |> render_click()

    view
    |> element(~s(button[phx-click="remove_column"][phx-value-column_id="avatar"]))
    |> render_click()

    doc = doc(view)
    refute "Avatar" in header_texts(doc)
    assert [] = doc |> row("#{m}-ann@") |> Floki.find(".avatar")
  end

  test "an avatar with a picture shows a larger copy on hover, and its click opens the user",
       %{conn: conn, admin: admin} do
    m = marker()
    person = F.person(%{email: "#{m}-pic@example.com"})

    {:ok, _} =
      Auth.update_user_fields(person, %{
        "avatar_file_uuid" => Ecto.UUID.generate()
      })

    F.person(%{email: "#{m}-plain@example.com"})
    {:ok, view, _html} = open(conn, admin, "?q=#{m}")
    doc = doc(view)

    [peek] =
      doc |> row("#{m}-pic@") |> Floki.find(".avatar") |> Floki.attribute("data-avatar-peek")

    assert peek =~ "/medium/", "a picture sized for the preview, not the row's small one"

    assert [href] =
             doc
             |> row("#{m}-pic@")
             |> Floki.find("a.z-10:has(.avatar)")
             |> Floki.attribute("href")

    assert href =~ "/admin/users/view/#{person.uuid}"

    # Gravatar is tried for every address, so a plain avatar gets one too;
    # only enlarged initials would show nothing new.
    assert [_] =
             doc
             |> row("#{m}-plain@")
             |> Floki.find(".avatar")
             |> Floki.attribute("data-avatar-peek")
  end

  test "a grid card draws the avatar larger than a table row does",
       %{conn: conn, admin: admin} do
    m = marker()
    F.person(%{email: "#{m}-card@example.com"})
    {:ok, view, _html} = open(conn, admin, "?q=#{m}")

    assert [row_frame] = view |> doc() |> row("#{m}-card@") |> Floki.find("[data-avatar-frame]")
    assert row_frame |> Floki.attribute("class") |> hd() =~ "w-12 h-12"

    render_click(view, "set_view_mode", %{"mode" => "card"})

    card_frames =
      view
      |> doc()
      |> Floki.find(".card-body [data-avatar-frame]")
      |> Enum.filter(&(&1 |> Floki.attribute("class") |> hd() =~ "w-16 h-16"))

    assert [_] = card_frames
  end

  describe "a custom field's column name" do
    test "heads the column and the picker, with the full label on hover and under it; cards keep the label",
         %{conn: conn, admin: admin} do
      key = "approved_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => key,
          "label" => "Approved for Wood Matrix",
          "type" => "boolean",
          "column_label" => "  Approved  "
        })

      assert CustomFields.get_field_definition(key)["column_label"] == "Approved"

      # An update that does not mention it keeps it.
      {:ok, _} = CustomFields.update_field_definition(key, %{"position" => 5})
      assert CustomFields.get_field_definition(key)["column_label"] == "Approved"

      {:ok, _} = TableColumns.update_user_table_columns(["email", "custom_#{key}"])

      {:ok, view, _html} = open(conn, admin)
      doc = doc(view)
      assert Floki.attribute(header(doc, "Approved"), "title") == ["Approved for Wood Matrix"]
      assert Floki.attribute(header(doc, "Account"), "title") == []

      # The picker reads like the header, with the full label under it.
      picker =
        view
        |> element(~s(button[phx-click="show_column_modal"]))
        |> render_click()
        |> Floki.parse_document!()

      shown = Floki.find(picker, ~s(li[data-id="custom_#{key}"]))
      assert squish(shown) == "Approved Approved for Wood Matrix"

      assert shown |> Floki.find("span.text-xs") |> Floki.text() |> String.trim() ==
               "Approved for Wood Matrix"

      # A standard column stays one line.
      assert [] = picker |> Floki.find(~s(li[data-id="email"])) |> Floki.find("span.text-xs")

      view
      |> element(~s(button[phx-click="remove_column"][phx-value-column_id="custom_#{key}"]))
      |> render_click()

      available =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find(~s(button[phx-click="add_column"][phx-value-column_id="custom_#{key}"]))

      assert squish(available) == "Approved Approved for Wood Matrix"
      render_click(view, "add_column", %{"column_id" => "custom_#{key}"})

      render_click(view, "hide_column_modal", %{})
      html = render_click(view, "set_view_mode", %{"mode" => "card"})
      assert html =~ ~s(text-base-content/60 min-w-0">Approved for Wood Matrix<)
    end

    test "blank or spaces only falls back to the label, with no hover text", %{
      conn: conn,
      admin: admin
    } do
      key = "approved_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => key,
          "label" => "Approved for Wood Matrix",
          "type" => "boolean",
          "column_label" => "Approved"
        })

      {:ok, _} = CustomFields.update_field_definition(key, %{"column_label" => "   "})
      refute Map.has_key?(CustomFields.get_field_definition(key), "column_label")

      {:ok, _} = TableColumns.update_user_table_columns(["email", "custom_#{key}"])
      {:ok, view, _html} = open(conn, admin)
      doc = doc(view)

      refute header(doc, "Approved")
      assert Floki.attribute(header(doc, "Approved for Wood Matrix"), "title") == []
    end

    test "the field editor saves a column name and, for a boolean, the filter switch", %{
      conn: conn,
      admin: admin
    } do
      key = "approved_#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(log_in_user(conn, admin), Routes.path("/admin/settings/users"))

      html = render_click(view, "show_add_field_form", %{})
      assert html =~ ~s(name="field[column_label]")
      assert html =~ "Leave blank to use the label."
      refute html =~ ~s(name="field[filterable]")

      html = render_click(view, "field_type_changed", %{"field" => %{"type" => "boolean"}})
      assert html =~ ~s(name="field[filterable]")

      render_submit(view, "save_field", %{
        "field" => %{
          "key" => key,
          "label" => "Approved for Wood Matrix",
          "column_label" => "Approved",
          "type" => "boolean",
          "filterable" => "true"
        }
      })

      assert %{"column_label" => "Approved", "filterable" => true} =
               CustomFields.get_field_definition(key)

      html = render_click(view, "show_edit_field_form", %{"key" => key})
      assert html =~ ~s(value="Approved")
    end
  end

  test "short labels: Roles, and small email badges", %{conn: conn, admin: admin} do
    m = marker()
    F.person(%{email: "#{m}-done@example.com"})
    F.person(%{email: "#{m}-wait@example.com", confirmed_at: nil})

    {:ok, view, _html} = open(conn, admin, "?q=#{m}")
    doc = doc(view)

    assert "Roles" in header_texts(doc)
    refute "Role" in header_texts(doc)

    assert [done | _] = doc |> cell("#{m}-done@", "Status") |> Floki.find("span.badge")
    assert String.trim(Floki.text(done)) == "Email ✓"
    assert Floki.attribute(done, "title") == ["Email confirmed"]
    assert Floki.attribute(done, "class") |> hd() =~ "badge-xs"

    assert [wait | _] = doc |> cell("#{m}-wait@", "Status") |> Floki.find("span.badge")
    assert String.trim(Floki.text(wait)) == "Email pending"
    assert Floki.attribute(wait, "class") |> hd() =~ "badge-xs"
  end

  test "dates do not wrap, and a narrow table drops columns in the agreed order", %{
    conn: conn,
    admin: admin
  } do
    key = "approved_#{System.unique_integer([:positive])}"

    {:ok, _} =
      CustomFields.add_field_definition(%{
        "key" => key,
        "label" => "Approved",
        "type" => "boolean"
      })

    {:ok, _} =
      TableColumns.update_user_table_columns(
        ~w(avatar email username full_name organizations role status registered location last_confirmed) ++
          ["custom_#{key}"]
      )

    m = marker()
    F.person(%{email: "#{m}-ann@example.com"})
    {:ok, view, _html} = open(conn, admin, "?q=#{m}")
    doc = doc(view)

    assert [_] = Floki.find(doc, ~s(div#users-table-fit[phx-hook="TableFit"]))

    priorities =
      doc
      |> Floki.find("table thead th")
      |> Map.new(fn th ->
        {String.trim(Floki.text(th)), Floki.attribute(th, "data-col-priority")}
      end)

    assert priorities == %{
             "Location" => ["10"],
             "Last Confirmed" => ["9"],
             "Username" => ["8"],
             "Full Name" => ["7"],
             "Registered" => ["6"],
             "Avatar" => ["5"],
             "Organizations" => ["4"],
             "Roles" => ["3"],
             "Status" => ["2"],
             "Approved" => ["1"],
             "Account" => [],
             "" => []
           }

    assert Floki.attribute(header(doc, "Account"), "data-col-lead") != []

    for date_column <- ["Registered", "Last Confirmed"] do
      assert doc |> cell("#{m}-ann@", date_column) |> Floki.attribute("class") |> hd() =~
               "whitespace-nowrap"
    end
  end

  describe "filtering by a boolean custom field" do
    setup do
      key = "approved_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => key,
          "label" => "Approved for Wood Matrix",
          "column_label" => "Approved",
          "type" => "boolean",
          "filterable" => true
        })

      m = marker()

      for {name, fields} <- [
            {"yes1", %{key => true}},
            {"yes2", %{key => "true"}},
            {"no1", %{key => false}},
            {"no2", %{key => "false"}},
            {"none", %{}}
          ] do
        F.person(%{email: "#{m}-#{name}@example.com", custom_fields: fields})
      end

      %{key: key, m: m}
    end

    test ~s(No lists false, "false" and never marked; Yes lists true and "true"), %{
      key: key,
      m: m
    } do
      assert listed_emails(search: m, custom_fields: [{key, :no}]) ==
               ["#{m}-no1@example.com", "#{m}-no2@example.com", "#{m}-none@example.com"]

      assert listed_emails(search: m, custom_fields: [{key, :yes}]) ==
               ["#{m}-yes1@example.com", "#{m}-yes2@example.com"]
    end

    test "the count and the pages are of the matching users only", %{key: key, m: m} do
      assert %{total_count: 3, total_pages: 2, users: [_, _]} =
               AuthCtx.list_users_paginated(search: m, custom_fields: [{key, :no}], page_size: 2)
    end

    test "the filter lives in the URL and survives a reload", %{
      conn: conn,
      admin: admin,
      key: key,
      m: m
    } do
      {:ok, view, _html} = open(conn, admin, "?q=#{m}&cf=#{key}:no")
      doc = doc(view)

      shown = doc |> Floki.find("table tbody tr") |> length()
      assert shown == 3
      refute row(doc, "#{m}-yes1@")

      button = Floki.find(doc, "#users-filter-cf-#{key} div[role=button]")
      assert squish(button) == "Approved: No"

      # The menu sends its pick as `choice`: a `phx-value-value` is replaced by
      # the button's own empty `value` in a browser, which LiveViewTest skips.
      html = render(view)
      assert html =~ ~s(phx-value-choice="yes")
      refute html =~ "phx-value-value"

      view
      |> element(~s(#users-filter-cf-#{key} button[phx-value-choice="yes"]))
      |> render_click()

      path = assert_patch(view)
      assert URI.decode_query(URI.parse(path).query)["cf"] == "#{key}:yes"

      {:ok, view, _html} = live(log_in_user(build_conn(), admin), path)
      doc = doc(view)
      assert row(doc, "#{m}-yes1@") && row(doc, "#{m}-yes2@")
      refute row(doc, "#{m}-none@")

      view
      |> element(~s(#users-filter-cf-#{key} button[phx-value-choice="any"]))
      |> render_click()

      refute URI.decode_query(URI.parse(assert_patch(view)).query || "")["cf"]
    end

    test "a pick works with the payload a browser sends", %{
      conn: conn,
      admin: admin,
      key: key,
      m: m
    } do
      {:ok, view, _html} = open(conn, admin, "?q=#{m}")

      # What Chromium sent for "No" (checked in a real browser): the button's
      # empty `value` rides along.
      render_click(view, "filter_by_custom_field", %{
        "key" => key,
        "choice" => "no",
        "value" => ""
      })

      assert URI.decode_query(URI.parse(assert_patch(view)).query)["cf"] == "#{key}:no"
      assert view |> doc() |> Floki.find("table tbody tr") |> length() == 3
    end

    test "Clear Filters drops it with the rest", %{conn: conn, admin: admin, key: key, m: m} do
      {:ok, view, _html} = open(conn, admin, "?q=#{m}&cf=#{key}:no")
      render_click(view, "clear_filters", %{})
      assert assert_patch(view) == Routes.path("/admin/users")
    end

    test "a field not marked for filtering, or an unknown one, is not a filter", %{
      conn: conn,
      admin: admin,
      m: m
    } do
      other = "plain_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => other,
          "label" => "Plain",
          "type" => "boolean"
        })

      {:ok, view, _html} = open(conn, admin, "?q=#{m}&cf=#{other}:yes,nope:no,broken")
      doc = doc(view)

      assert doc |> Floki.find("table tbody tr") |> length() == 5
      assert [] = Floki.find(doc, "#users-filter-cf-#{other}")
    end

    test "with only this filter on and no match, the empty state offers Clear Filters", %{
      conn: conn,
      admin: admin
    } do
      empty = "never_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => empty,
          "label" => "Never",
          "type" => "boolean",
          "filterable" => true
        })

      {:ok, view, _html} = open(conn, admin, "?cf=#{empty}:yes")
      html = render(view)
      assert html =~ "No users found"
      assert html =~ "Clear Filters"
      refute html =~ "No users are registered yet."
    end
  end

  test "with only the status filter on and no match, the empty state offers Clear Filters", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, _html} = open(conn, admin, "?status=inactive")
    html = render(view)
    assert html =~ "No users found"
    assert html =~ "Clear Filters"
  end
end
