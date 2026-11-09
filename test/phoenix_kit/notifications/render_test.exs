defmodule PhoenixKit.Notifications.RenderTest do
  # DataCase (not plain ExUnit) because Render builds links via Routes.path,
  # which reads language/prefix settings from the DB.
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Utils.Routes

  defp notif(action, metadata \\ %{}) do
    %Notification{
      activity: %Entry{action: action, metadata: metadata, actor_uuid: "actor-uuid"}
    }
  end

  describe "render/2 link — core account actions" do
    @account_actions ~w(
      user.roles_updated user.status_changed user.password_changed user.password_reset
      user.email_changed user.email_confirmed user.email_unconfirmed user.avatar_changed
      user.avatar_crop_changed user.profile_updated user.note_created user.note_deleted
    )

    test "each account action links to the prefix/locale-correct settings path" do
      for action <- @account_actions do
        assert Render.render(notif(action), "en").link ==
                 Routes.user_settings_path(locale: "en"),
               "expected #{action} to link to the settings page"
      end
    end

    test "the locale is threaded into the built link" do
      en = Render.render(notif("user.note_created"), "en").link
      ru = Render.render(notif("user.note_created"), "ru").link

      assert en == Routes.user_settings_path(locale: "en")
      assert ru == Routes.user_settings_path(locale: "ru")
    end

    test "render/1 (no locale) falls back to Routes.path's default-locale resolution" do
      assert Render.render(notif("user.note_created")).link ==
               Routes.user_settings_path()
    end

    test "an admin re-framing someone's avatar reads like a new avatar" do
      # AvatarEditor logs it with the person as target when an admin does it.
      view = Render.render(notif("user.avatar_crop_changed"), "en")

      assert view.icon == "hero-user-circle"
      assert view.text == "Your avatar was updated."
      assert Types.key_for_action("user.avatar_crop_changed") == "account"
    end

    test "user.email_unconfirmed renders a dedicated icon/text, not the generic fallback" do
      view = Render.render(notif("user.email_unconfirmed"), "en")

      assert view.icon == "hero-exclamation-circle"
      assert view.text == "Your email is no longer confirmed."
    end

    test "a link change has account preferences, copy and a settings link" do
      action = "organization.manager_changed"
      view = Render.render(notif(action, %{"organization_name" => "Oak Trading"}), "en")

      assert Types.key_for_action(action) == "account"
      assert view.text == "Your access to act for Oak Trading was updated."
      assert view.link == Routes.user_settings_path(locale: "en")

      assert Render.render(notif(action), "de").text !=
               Render.render(notif(action), "en").text
    end
  end

  describe "render/2 — session actions reach the recipient's inbox" do
    # Both are logged with `target_uuid` set to the account that was ADDED, so
    # `maybe_create_from_activity/1` delivers them to that person. Without a
    # clause they rendered as the humanized action ("Session impersonated"),
    # which reads as a log line rather than a notice addressed to them.
    test "session.impersonated says who did what, not the raw action name" do
      view = Render.render(notif("session.impersonated"), "en")

      assert view.icon == "hero-identification"
      assert view.text == "An administrator signed in to your account for support."
    end

    test "session.account_added has its own copy too" do
      view = Render.render(notif("session.account_added"), "en")

      assert view.icon == "hero-user-plus"
      assert view.text == "Your account was added to another sign-in session."
    end

    test "both are claimed by a preference type, so they can be muted" do
      # An action no type claims is fail-open and therefore unmuteable — it
      # never appears in the preferences UI for the user to switch off.
      assert Types.type_for_action("session.impersonated") == "security"
      assert Types.type_for_action("session.account_added") == "security"
    end
  end

  describe "render/2 link — module-owned / unknown actions return nil" do
    test "social and account-gone and unknown actions have no core link" do
      for action <-
            ~w(user.followed post.liked post.commented comment.liked user.deleted totally.unknown) do
        assert Render.render(notif(action), "en").link == nil,
               "expected #{action} to have no core-built link (emitter must set notification_link)"
      end
    end

    test "user.followed no longer mis-routes to settings" do
      refute Render.render(notif("user.followed"), "en").link ==
               Routes.user_settings_path(locale: "en")
    end
  end

  describe "render/2 link — notification_link metadata override" do
    test "wins verbatim over a core account link" do
      link =
        Render.render(notif("user.note_created", %{"notification_link" => "/p/x"}), "en").link

      assert link == "/p/x"
    end

    test "supplies the link for module-owned actions that have none" do
      link = Render.render(notif("post.liked", %{"notification_link" => "/posts/1"}), "en").link
      assert link == "/posts/1"
    end

    test "blank override is ignored (falls through to the action link)" do
      link = Render.render(notif("user.note_created", %{"notification_link" => ""}), "en").link
      assert link == Routes.user_settings_path(locale: "en")
    end
  end

  describe "render/2 link — standalone notification (no activity)" do
    test "uses its own metadata notification_link, else nil" do
      # activity: nil mirrors a preloaded standalone notification (no activity_uuid).
      assert Render.render(%Notification{activity: nil, metadata: %{"notification_link" => "/s"}}).link ==
               "/s"

      assert Render.render(%Notification{activity: nil, metadata: %{}}).link == nil
    end
  end

  describe "render/2 text — the recipient's locale" do
    test "renders the default text in the recipient's language" do
      assert Render.render(notif("user.password_reset"), "en").text == "Your password was reset."
      assert Render.render(notif("user.password_reset"), "ru").text == "Ваш пароль сброшен."
    end

    test "interpolates metadata into the translated sentence" do
      notification = notif("user.email_changed", %{"new_email" => "new@example.com"})

      assert Render.render(notification, "de").text ==
               "Ihre E-Mail-Adresse wurde zu new@example.com geändert."
    end

    test "picks the shorter sentence when the metadata detail is absent or empty" do
      # Two complete msgids rather than a translated stem with a concatenated
      # suffix — a suffix is unorderable, and several languages need the detail
      # somewhere other than the end.
      for meta <- [%{}, %{"new_email" => ""}] do
        assert Render.render(notif("user.email_changed", meta), "de").text ==
                 "Ihre E-Mail-Adresse wurde geändert."
      end
    end

    test "localizes the standalone (activity-less) notification fallback" do
      # activity: nil mirrors a preloaded standalone notification; a bare
      # %Notification{} carries NotLoaded, which is a struct and takes the
      # activity clause.
      notification = %Notification{activity: nil, metadata: %{}}

      assert Render.render(notification, "ru").text == "У вас новое уведомление."
    end

    test "a dialect locale (the inbox path) renders its base language" do
      notification = %Notification{activity: nil, metadata: %{}}
      spanish = Render.render(notification, "es").text

      refute spanish == "You have a new notification."
      assert Render.render(notification, "es-ES").text == spanish
    end

    test "does not leak the recipient's locale onto the calling process" do
      # These render on a background worker that goes on to handle other
      # recipients; a leaked locale would mistranslate every later message.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      assert Render.render(notif("user.password_reset"), "ru").text == "Ваш пароль сброшен."
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "en"
    end

    test "a nil locale leaves the caller's own locale in force" do
      # The admin inbox renders in the viewer's language, not a recipient's.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")
      assert Render.render(notif("user.password_reset")).text == "Ваш пароль сброшен."
    end
  end
end
