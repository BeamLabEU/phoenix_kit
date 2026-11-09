defmodule PhoenixKit.Integration.Users.OrganizationProfileNamesTest do
  @moduledoc """
  An organization has a name, not a first and a last one (2026-11-09): its
  settings form edits the name, a profile save never writes first or last
  names for it and never blanks the name, and the admin form turning a
  company into a person still saves the names typed with it.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    :ok
  end

  describe "profile_changeset/3" do
    test "an organization's first and last names are not written" do
      org = F.organization(%{organization_name: "Oak Trading"})
      changeset = User.profile_changeset(org, %{"first_name" => "Ann", "last_name" => "Lee"})

      refute Ecto.Changeset.changed?(changeset, :first_name)
      refute Ecto.Changeset.changed?(changeset, :last_name)
    end

    test "an organization's name can change but not to nothing" do
      org = F.organization(%{organization_name: "Oak Trading"})

      assert User.profile_changeset(org, %{"organization_name" => "Oak Ltd"}).valid?
      refute User.profile_changeset(org, %{"organization_name" => ""}).valid?
    end

    test "a person's profile carries no organization name" do
      person = F.person()
      changeset = User.profile_changeset(person, %{"organization_name" => "Oak"})

      refute Ecto.Changeset.changed?(changeset, :organization_name)
    end

    test "the type submitted with the save decides, for a form that changes it" do
      org = F.organization(%{organization_name: "Oak Trading", managed_by_members: false})

      changeset =
        User.profile_changeset(org, %{"account_type" => "person", "first_name" => "Ann"})

      assert Ecto.Changeset.get_change(changeset, :first_name) == "Ann"
    end
  end

  test "the admin form turning a company into a person saves the names typed with it" do
    {_actor, admin} = F.admin_actor()
    org = F.organization(%{organization_name: "Birch AS", managed_by_members: false})

    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/users/edit/#{org.uuid}"))

    view |> form("#user_form", %{"user" => %{"account_type" => "person"}}) |> render_change()

    view
    |> form("#user_form", %{
      "user" => %{"account_type" => "person", "first_name" => "Ann", "last_name" => "Lee"}
    })
    |> render_submit()

    saved = Repo.get!(User, org.uuid)
    assert saved.account_type == "person"
    assert {saved.first_name, saved.last_name} == {"Ann", "Lee"}
  end

  test "an organization's own settings edit its name, with no first or last name fields" do
    s = F.acting_session()

    conn =
      init_test_session(build_conn(), %{
        user_token: s.token,
        pk_session_accounts: [s.root_token, s.token],
        pk_organization_token: s.token
      })

    {:ok, view, html} = live(conn, Routes.path("/profile/settings/account"))

    assert html =~ "Organization Name"
    refute html =~ "First Name"

    render_click(with_target(view, "[data-phx-component='1']"), "update_profile", %{
      "user" => %{"organization_name" => "Acme Group", "first_name" => "Forged"}
    })

    saved = Repo.get!(User, s.organization.uuid)
    assert saved.organization_name == "Acme Group"
    assert saved.first_name == nil
  end
end
