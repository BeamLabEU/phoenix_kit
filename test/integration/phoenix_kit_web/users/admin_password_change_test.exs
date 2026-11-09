defmodule PhoenixKitWeb.Users.AdminPasswordChangeTest do
  @moduledoc """
  An admin setting a user's password on `/admin/users/edit/:id` either changes
  it or says why not.

  Reported as: the form said it worked and the user could not sign in with the
  new password. `Auth.admin_update_user_password/3` is not the problem — it
  hashes, writes, revokes the sessions and refuses the new password's
  predecessor. What matters is whether the form reaches it, and what the
  screen says when it does not.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.{Auth, Role, RoleAssignment, Roles}
  alias PhoenixKitWeb.Users.UserForm

  @new_password "BrandNewPassword123!"
  @old_password "OriginalPassword123!"

  defp user!(opts \\ []) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "admin-pw-#{System.unique_integer([:positive])}@example.com",
        "password" => Keyword.get(opts, :password, @old_password)
      })

    case Keyword.get(opts, :role) do
      nil -> user
      role -> promote!(user, role)
    end
  end

  # `Roles.assign_role/3` refuses the Owner role — it is only ever
  # bootstrapped onto the first user — so that one is inserted directly, the
  # way `session_multi_test.exs` seeds it.
  defp promote!(user, role) do
    roles = Role.system_roles()

    if role == roles.owner do
      owner_role = Roles.get_role_by_name(roles.owner)

      {:ok, _} =
        %RoleAssignment{}
        |> RoleAssignment.changeset(%{user_uuid: user.uuid, role_uuid: owner_role.uuid})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_uuid, :role_uuid])
    else
      {:ok, _} = Roles.assign_role(user, role)
    end

    Auth.get_user(user.uuid)
  end

  # The form's socket at the moment Save is pressed, with the password field
  # opened by the "Change Password" button.
  defp edit_socket(actor, target, opts \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        mode: :edit,
        user: target,
        phoenix_kit_current_user: actor,
        show_password_field: Keyword.get(opts, :password_field_open, true),
        can_manage_credentials: true,
        current_account_type: target.account_type,
        # Roles untouched by this save: `pending_roles` equals `user_roles`,
        # so `update_user_roles_if_changed/2` short-circuits.
        user_roles: [],
        pending_roles: [],
        return_to: "/admin/users",
        changeset: Auth.change_user_registration(target, %{}),
        form_data: %{},
        custom_fields_data: %{}
      }
    }
  end

  defp signs_in?(user, password),
    do: match?({:ok, _}, Auth.get_user_by_email_and_password(user.email, password))

  describe "an owner setting a password" do
    test "changes it, and the new one works", %{} do
      owner = user!(role: Role.system_roles().owner)
      target = user!()

      assert signs_in?(target, @old_password)

      {:noreply, socket} =
        UserForm.handle_event(
          "save_user",
          %{"user" => %{"password" => @new_password}},
          edit_socket(owner, target)
        )

      assert signs_in?(target, @new_password), "the password the admin typed must be the one set"
      refute signs_in?(target, @old_password), "and the old one must stop working"
      refute socket.assigns.flash["error"]
    end
  end

  describe "an owner setting a password on a real submission" do
    test "the whole form, as the page posts it", %{} do
      # Not just `%{"password" => ...}`: the page submits every field it
      # renders, and the save threads the user struct through a profile write,
      # custom fields, account type and roles after the password is set.
      owner = user!(role: Role.system_roles().owner)
      target = user!()

      {:noreply, socket} =
        UserForm.handle_event(
          "save_user",
          %{
            "user" => %{
              "email" => target.email,
              "username" => target.username,
              "first_name" => "Kept",
              "last_name" => "Name",
              "user_timezone" => "0",
              "account_type" => target.account_type,
              "is_active" => "true",
              "password" => @new_password,
              "custom_fields" => %{}
            }
          },
          edit_socket(owner, target)
        )

      refute socket.assigns.flash["error"]
      assert signs_in?(target, @new_password), "the password on a full submission must land"
      refute signs_in?(target, @old_password)
      assert Auth.get_user(target.uuid).first_name == "Kept"
    end

    test "the user can then sign in the way the login page asks", %{} do
      # `get_user_by_email_or_username_and_password/3` is what the session
      # controller calls — by email, or by username when the identifier has no
      # "@". Both must accept the password the admin just set.
      owner = user!(role: Role.system_roles().owner)
      target = user!()
      username_before = target.username

      {:noreply, _socket} =
        UserForm.handle_event(
          "save_user",
          %{"user" => %{"email" => target.email, "password" => @new_password}},
          edit_socket(owner, target)
        )

      after_save = Auth.get_user(target.uuid)

      assert after_save.username == username_before,
             "a save that did not touch the username must not rewrite it — " <>
               "logging in by username is a route the account keeps"

      assert match?(
               {:ok, _},
               Auth.get_user_by_email_or_username_and_password(target.email, @new_password)
             ),
             "signing in by email"

      assert match?(
               {:ok, _},
               Auth.get_user_by_email_or_username_and_password(after_save.username, @new_password)
             ),
             "signing in by username"
    end
  end

  describe "when the actor may not manage this account's credentials" do
    test "it says so instead of reporting success", %{} do
      # An Admin does not outrank an Owner. The password is dropped at the
      # write path — correctly — but the form used to carry on through the
      # profile update and flash "user updated", so the screen said the
      # password had been set while the account kept the old one.
      admin = user!(role: Role.system_roles().admin)
      owner_target = user!(role: Role.system_roles().owner)

      {:noreply, socket} =
        UserForm.handle_event(
          "save_user",
          %{"user" => %{"password" => @new_password}},
          edit_socket(admin, owner_target)
        )

      refute signs_in?(owner_target, @new_password), "the password is not the actor's to set"
      assert signs_in?(owner_target, @old_password)

      assert socket.assigns.flash["error"],
             "a refusal has to reach the screen — silence reads as success"

      refute socket.assigns.flash["info"]
    end

    test "but an ordinary save of other fields still goes through", %{} do
      # The form submits `email` and `username` on every save, unchanged. If
      # echoing them back counted as an attempt, an Admin could no longer edit
      # anything at all on an account they may not manage the credentials of —
      # a fix that trades a silent failure for a blanket one.
      admin = user!(role: Role.system_roles().admin)
      owner_target = user!(role: Role.system_roles().owner)

      {:noreply, socket} =
        UserForm.handle_event(
          "save_user",
          %{
            "user" => %{
              "email" => owner_target.email,
              "username" => owner_target.username,
              "first_name" => "Renamed",
              "password" => ""
            }
          },
          edit_socket(admin, owner_target)
        )

      refute socket.assigns.flash["error"], "nothing was asked for that is out of rank"
      assert Auth.get_user(owner_target.uuid).first_name == "Renamed"
    end

    test "rewriting the email is refused the same way", %{} do
      # Owning the address a reset link goes to takes an account just as
      # surely as setting the password does.
      admin = user!(role: Role.system_roles().admin)
      owner_target = user!(role: Role.system_roles().owner)

      {:noreply, socket} =
        UserForm.handle_event(
          "save_user",
          %{
            "user" => %{"email" => "taken-over-#{System.unique_integer([:positive])}@example.com"}
          },
          edit_socket(admin, owner_target)
        )

      assert socket.assigns.flash["error"]
      assert Auth.get_user(owner_target.uuid).email == owner_target.email
    end
  end
end
