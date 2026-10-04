defmodule PhoenixKit.Integration.Notifications.EmailChannelTest do
  @moduledoc """
  The email notification channel sends core's `notification` email: in the
  shared layout, overridable with files, with the same text as before.
  """

  # `template_paths` is global application env: not async.
  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Notifications.Channels.Email
  alias PhoenixKit.Users.Auth

  defp reader do
    {:ok, user} =
      Auth.register_user(%{
        email: "notified_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp envelope(user, overrides) do
    Map.merge(
      %{
        recipient_uuid: user.uuid,
        type_key: "comments",
        notification_uuid: nil,
        locale: "en",
        icon: "hero-bell",
        title: nil,
        text: "Acme Ltd commented on <your> order",
        url: "https://shop.example.test/orders/1"
      },
      overrides
    )
  end

  test "text and link in the text body, escaped paragraphs in the layout" do
    user = reader()

    assert :ok = Email.deliver(envelope(user, %{}), %{})

    assert_email_sent(fn email ->
      assert email.to == [{"", user.email}]
      assert email.subject == "Acme Ltd commented on <your> order"

      assert email.text_body ==
               "Acme Ltd commented on <your> order\n\nhttps://shop.example.test/orders/1"

      assert email.html_body =~ "<!DOCTYPE html>"
      assert email.html_body =~ "Acme Ltd commented on &lt;your&gt; order"

      assert email.html_body =~
               ~s(<a href="https://shop.example.test/orders/1">https://shop.example.test/orders/1</a>)
    end)
  end

  test "the title is the subject; no link leaves no trailing blank line" do
    user = reader()

    assert :ok = Email.deliver(envelope(user, %{title: "New comment", url: nil}), %{})

    assert_email_sent(fn email ->
      refute email.html_body =~ ~r/<p[^>]*>\s*<\/p>/
      assert email.text_body == "Acme Ltd commented on <your> order"
      assert email.subject == "New comment"
    end)
  end

  test "a host file overrides the body" do
    root = Path.join(System.tmp_dir!(), "pk_notif_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "notification"))
    File.write!(Path.join(root, "notification/markdown.md"), "{{text}}\n\n[Open]({{url}})")
    on_exit(fn -> File.rm_rf!(root) end)

    previous = Application.get_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :template_paths, previous),
        else: Application.delete_env(:phoenix_kit, :template_paths)
    end)

    user = reader()
    assert :ok = Email.deliver(envelope(user, %{}), %{})

    assert_email_sent(fn email ->
      assert email.html_body =~
               ~s(<a href="https://shop.example.test/orders/1" style="display:inline-block;)

      assert email.text_body =~ "Open: https://shop.example.test/orders/1"
    end)
  end
end
