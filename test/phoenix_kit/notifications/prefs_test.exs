defmodule PhoenixKit.Notifications.PrefsTest do
  # DataCase — user_wants?/2 loads the user (and thus prefs) from the DB.
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Users.Auth

  # Register a confirmed-enough user and set their notification_preferences map.
  defp user_with_prefs(prefs) do
    email = "prefs-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    {:ok, user} = Auth.update_user_custom_fields(user, %{"notification_preferences" => prefs})
    user
  end

  describe "user_wants?/2 — hierarchical master switch" do
    test "muting account changes also mutes organization link changes" do
      user = user_with_prefs(%{"account" => false})
      refute Prefs.user_wants?(user.uuid, "organization.manager_changed")
    end

    test "empty prefs → sub-types delivered per their default (true)" do
      user = user_with_prefs(%{})
      assert Prefs.user_wants?(user.uuid, "comment.replied")
      assert Prefs.user_wants?(user.uuid, "post.liked")
    end

    test "base OFF mutes every sub-type (old flat mute, back-compat)" do
      user = user_with_prefs(%{"comments" => false})
      refute Prefs.user_wants?(user.uuid, "comment.replied")
      refute Prefs.user_wants?(user.uuid, "comment.liked")
    end

    test "base ON + one sub OFF mutes only that sub; sibling delivered" do
      user = user_with_prefs(%{"comments" => true, "comments.reactions" => false})
      assert Prefs.user_wants?(user.uuid, "comment.replied")
      refute Prefs.user_wants?(user.uuid, "comment.liked")
    end

    test "master wins over sub AND the stored sub value is preserved (not deleted)" do
      user = user_with_prefs(%{"comments" => false, "comments.replies" => true})
      # Muted by the master...
      refute Prefs.user_wants?(user.uuid, "comment.replied")
      # ...but the sub's stored `true` survives, so re-enabling the master restores it.
      assert Prefs.get(user)["comments.replies"] == true
    end

    test "back-compat: old flat base-key prefs act as masters" do
      off = user_with_prefs(%{"posts" => false})
      refute Prefs.user_wants?(off.uuid, "post.liked")

      on = user_with_prefs(%{"posts" => true})
      assert Prefs.user_wants?(on.uuid, "post.liked")
    end

    test "fail-open: unknown action is delivered" do
      user = user_with_prefs(%{"comments" => false})
      assert Prefs.user_wants?(user.uuid, "totally.unknown.action")
    end
  end

  describe "user_wants_type?/2 — direct key (base or dotted)" do
    test "base key checked directly" do
      user = user_with_prefs(%{"comments" => false})
      refute Prefs.user_wants_type?(user.uuid, "comments")
    end

    test "dotted key applies the master switch" do
      muted = user_with_prefs(%{"comments" => false, "comments.replies" => true})
      refute Prefs.user_wants_type?(muted.uuid, "comments.replies")

      live = user_with_prefs(%{"comments" => true, "comments.replies" => true})
      assert Prefs.user_wants_type?(live.uuid, "comments.replies")
    end
  end

  describe "merge/2 — merge-preserving write" do
    test "overlays provided keys without dropping others" do
      user = user_with_prefs(%{"comments" => true, "comments.replies" => false})
      {:ok, user} = Prefs.merge(user, %{"posts" => false})

      prefs = Prefs.get(user)
      # New key written...
      assert prefs["posts"] == false
      # ...and the untouched keys survive (the anti-clobber guarantee).
      assert prefs["comments"] == true
      assert prefs["comments.replies"] == false
    end

    test "a stale caller no longer clobbers sibling custom_fields keys" do
      # Both write surfaces hold a long-lived %User{} (the settings LiveView
      # loads it in mount/3), while every sibling key in that column is
      # written atomically elsewhere — a channel connect or a locale switch
      # landing mid-session must survive the next preferences save.
      stale = user_with_prefs(%{"comments" => true})

      {:ok, _} =
        Auth.merge_user_custom_fields(
          stale,
          %{"notification_channel:telegram" => %{"chat_id" => "42"}},
          ensure_definitions: false
        )

      {:ok, updated} = Prefs.merge(stale, %{"posts" => false})

      assert Prefs.get(updated)["posts"] == false
      assert updated.custom_fields["notification_channel:telegram"] == %{"chat_id" => "42"}
    end
  end
end
