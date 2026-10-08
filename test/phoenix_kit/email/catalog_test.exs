defmodule PhoenixKit.Email.CatalogTest do
  @moduledoc """
  The email catalog: which emails the system knows, and their previews.

  Core's emails come from `CoreTemplates`; modules add theirs through
  `email_templates/0`. A preview runs the same resolution as a send, so the
  checks here pin both the list and that the send and the preview share one
  copy.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Mailer
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Notifications.Channels.Email, as: EmailChannel
  alias PhoenixKit.Templates
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @translated_names ~w(register reset_password update_email magic_link magic_link_registration
                       organization_invitation new_login_alert failed_login_alert welcome)
  @core_names @translated_names ++ ["notification"]

  defmodule EnabledEmailModule do
    @moduledoc false
    def enabled?, do: true
    def module_name, do: "Fixture Billing"

    def email_templates do
      [
        %{
          name: "fixture_invoice",
          label: "Invoice",
          defaults: fn -> %{subject: "Invoice {{number}}", markdown: "Pay [now]({{pay_url}})"} end,
          variables: %{"number" => "INV-1", "pay_url" => "https://pay.example.test/1"},
          layout: "billing"
        },
        # A name core already lists: core's entry stays.
        %{name: "register", label: "Hijacked"},
        # Not a template name: dropped.
        %{name: "_layout", label: "Reserved"},
        %{name: "Bad Name", label: "Spaces"},
        :not_a_map
      ]
    end
  end

  defmodule DisabledEmailModule do
    @moduledoc false
    def enabled?, do: false
    def email_templates, do: [%{name: "fixture_disabled", label: "Disabled"}]
  end

  defmodule WarnOnceEmailModule do
    @moduledoc false
    def enabled?, do: true

    def email_templates do
      [
        %{name: "Warn Once Bad", label: "x"},
        %{name: "warn_once_dup", label: "first"},
        %{name: "warn_once_dup", label: "second"},
        %{label: "no name"},
        "not a map"
      ]
    end
  end

  defmodule ThrowingEmailModule do
    @moduledoc false
    def enabled?, do: true
    def email_templates, do: throw(:no_list)
  end

  defmodule ExitingEmailModule do
    @moduledoc false
    def enabled?, do: true
    def email_templates, do: exit(:gone)
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "pk_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "entries/0" do
    test "lists core's emails first, in order, each with a label, defaults and samples" do
      entries = Catalog.entries()
      core = Enum.take(entries, length(@core_names))

      assert Enum.map(core, & &1.name) == @core_names

      for entry <- core do
        assert entry.module == nil
        assert is_binary(entry.label) and entry.label != ""
        assert is_function(entry.defaults, 0)
        assert is_function(entry.variables, 0)
      end
    end

    test "adds an enabled module's emails, tagged with the module; drops invalid ones" do
      ModuleRegistry.register(EnabledEmailModule)
      ModuleRegistry.register(DisabledEmailModule)

      try do
        entries = Catalog.entries()
        names = Enum.map(entries, & &1.name)

        assert %{module: EnabledEmailModule, layout: "billing"} =
                 Enum.find(entries, &(&1.name == "fixture_invoice"))

        # core wins a clash, and appears once
        assert Enum.count(names, &(&1 == "register")) == 1
        assert Catalog.get("register").label != "Hijacked"

        refute "_layout" in names
        refute "Bad Name" in names
        refute "fixture_disabled" in names
      after
        ModuleRegistry.unregister(EnabledEmailModule)
        ModuleRegistry.unregister(DisabledEmailModule)
      end
    end
  end

  describe "entries/0 robustness" do
    test "a module whose callback throws or exits leaves the list intact" do
      ModuleRegistry.register(ThrowingEmailModule)
      ModuleRegistry.register(ExitingEmailModule)

      try do
        capture_log(fn ->
          assert Enum.take(Catalog.entries(), length(@core_names)) |> Enum.map(& &1.name) ==
                   @core_names
        end)
      after
        ModuleRegistry.unregister(ThrowingEmailModule)
        ModuleRegistry.unregister(ExitingEmailModule)
      end
    end

    test "a bad entry is warned about once, not on every call" do
      ModuleRegistry.register(WarnOnceEmailModule)

      try do
        first = capture_log(fn -> Catalog.entries() end)
        second = capture_log(fn -> Catalog.entries() end)

        assert first =~ ~s("Warn Once Bad")
        assert first =~ ~s("warn_once_dup")
        assert first =~ "has no name"
        assert first =~ "non-map entry"
        assert second == ""

        assert [%{label: "first"}] =
                 Enum.filter(Catalog.entries(), &(&1.name == "warn_once_dup"))
      after
        ModuleRegistry.unregister(WarnOnceEmailModule)
      end
    end
  end

  # The English copy is the msgid every translation is keyed on: changing a
  # word here silently reverts that email to English in every language until
  # the catalogues are updated. Change these literals only together with them.
  describe "core's default copy" do
    test "is exactly the copy the translations are keyed on" do
      Gettext.with_locale(PhoenixKitWeb.Gettext, "en", fn ->
        assert CoreTemplates.register_defaults() == %{
                 subject: "Confirm your account",
                 markdown: """
                 Hi {{user_email}},

                 Please confirm your account with the button below.

                 [Confirm account]({{confirmation_url}})

                 If the button doesn't work, open this link: [{{confirmation_url}}]({{confirmation_url}})

                 If you didn't create an account with us, please ignore this email.
                 """
               }

        assert CoreTemplates.reset_password_defaults() == %{
                 subject: "Reset your password",
                 markdown: """
                 Hi {{user_email}},

                 You can reset your password with the button below.

                 [Reset password]({{reset_url}})

                 If the button doesn't work, open this link: [{{reset_url}}]({{reset_url}})

                 If you didn't request this change, please ignore this email.
                 """
               }

        assert CoreTemplates.update_email_defaults() == %{
                 subject: "Confirm your email change",
                 markdown: """
                 Hi {{user_email}},

                 You can change your email with the button below.

                 [Confirm email change]({{update_url}})

                 If the button doesn't work, open this link: [{{update_url}}]({{update_url}})

                 If you didn't request this change, please ignore this email.
                 """
               }

        assert CoreTemplates.magic_link_defaults() == %{
                 subject: "Your secure login link",
                 markdown: """
                 Hi {{user_email}},

                 Use the button below to sign in. This link expires in 15 minutes.

                 [Sign in]({{magic_link_url}})

                 If the button doesn't work, open this link: [{{magic_link_url}}]({{magic_link_url}})

                 If you didn't ask for this link, you can ignore this email.
                 """
               }

        assert CoreTemplates.magic_link_registration_defaults() == %{
                 subject: "Complete your registration",
                 markdown: """
                 Hi {{user_email}},

                 Welcome! To complete your registration, use the button below.

                 [Complete registration]({{registration_url}})

                 If the button doesn't work, open this link: [{{registration_url}}]({{registration_url}})

                 This link will expire in 30 minutes for your security.

                 If you didn't request this registration, please ignore this email.
                 """
               }

        assert CoreTemplates.organization_invitation_defaults() == %{
                 subject: "You've been invited to join {{organization_name}}",
                 markdown: """
                 Hi {{user_email}},

                 {{organization_name}} has invited you to join their organization.

                 To accept the invitation, register an account with the button below.

                 [Accept invitation]({{registration_url}})

                 If the button doesn't work, open this link: [{{registration_url}}]({{registration_url}})

                 This invitation link will expire in 7 days.

                 If you did not expect this invitation, you can safely ignore this email.
                 """
               }

        assert CoreTemplates.new_login_alert_defaults() == %{
                 subject: "New login to your account",
                 markdown: """
                 Hi {{user_email}},

                 We noticed a new login to your account from an unrecognized device:

                 - Time: {{login_time}}
                 - IP address: {{ip_address}}
                 - Location: {{location}}
                 - Device: {{browser_os}}

                 {{failed_attempts}}

                 If this was you, no action is needed.

                 If you don't recognize this activity, secure your account:

                 [Review account security]({{security_url}})

                 If the button doesn't work, open this link: [{{security_url}}]({{security_url}})
                 """
               }

        assert CoreTemplates.failed_login_alert_defaults() == %{
                 subject: "Failed sign-in attempts on your account",
                 markdown: """
                 Hi {{user_email}},

                 Someone has been trying to sign in to your account and failing.

                 - Failed attempts: {{attempt_count}}
                 - In the last: {{window_hours}} hour(s)

                 Nobody has signed in. You do not need to do anything if you recognize this as your own mistyped password.

                 If you do not, your password may be being guessed. Change it to something you do not use anywhere else:

                 [Change password]({{security_url}})

                 If the button doesn't work, open this link: [{{security_url}}]({{security_url}})
                 """
               }

        assert CoreTemplates.welcome_defaults() == %{
                 subject: "Welcome to {{site_name}}",
                 markdown: """
                 Hi {{user_email}},

                 Welcome to {{site_name}}! Your email address is confirmed and your account is ready.

                 [Go to {{site_name}}]({{site_url}})

                 If the button doesn't work, open this link: [{{site_url}}]({{site_url}})
                 """
               }
      end)
    end

    test "every core email is translated into every core language" do
      for entry <- Catalog.entries(), entry.name in @translated_names do
        english = Gettext.with_locale(PhoenixKitWeb.Gettext, "en", entry.defaults)
        assert english.subject not in [nil, ""]
        assert english.markdown not in [nil, ""]

        for locale <- ~w(de es et fr it pl ru uk) do
          translated = Gettext.with_locale(PhoenixKitWeb.Gettext, locale, entry.defaults)

          assert translated.subject not in [nil, ""], "#{entry.name} subject in #{locale}"
          assert translated.markdown not in [nil, ""], "#{entry.name} markdown in #{locale}"
          refute translated.subject == english.subject, "#{entry.name} subject in #{locale}"
          refute translated.markdown == english.markdown, "#{entry.name} markdown in #{locale}"

          # A translation keeps every placeholder and the button of the copy
          # it translates — a lost `{{confirmation_url}}` is a dead email.
          assert placeholders(translated.markdown) == placeholders(english.markdown),
                 "#{entry.name} placeholders in #{locale}"

          assert buttons(translated.markdown) == buttons(english.markdown),
                 "#{entry.name} button in #{locale}"
        end
      end
    end
  end

  # Which placeholders, not how often: a language may name the site once.
  defp placeholders(text),
    do:
      ~r/\{\{\s*([a-z_]+)\s*\}\}/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

  # The target of each paragraph that is exactly one link.
  defp buttons(text),
    do: ~r/^\[[^\]\n]+\]\(([^)\n]+)\)$/m |> Regex.scan(text, capture: :all_but_first)

  describe "preview/3 of core's emails" do
    for name <- ~w(register reset_password update_email magic_link magic_link_registration
                   organization_invitation new_login_alert failed_login_alert welcome) do
      test "#{name}: every placeholder has a sample, and all three versions render" do
        entry = Catalog.get(unquote(name))

        for locale <- ["en", "ru"] do
          assert {:ok, preview} = Catalog.preview(entry, locale, paths: [])

          assert preview.missing == %{}, "unbound in #{locale}: #{inspect(preview.missing)}"
          assert preview.content.subject not in [nil, ""]
          refute preview.content.subject =~ "{{"
          refute preview.content.text =~ "{{"
          assert preview.content.html =~ "<!DOCTYPE html>"
          assert preview.sources.subject == :default
          assert preview.sources.markdown == :default
          assert preview.sources.html_from == :markdown
          assert preview.sources.text_from == :markdown
          # The main action is a button, and the address is written out too.
          assert preview.content.html =~ ~s(style="display:inline-block;)
          refute preview.content.text =~ "]("
        end
      end
    end

    test "a dialect is rendered in its language, as a send to that reader is" do
      {:ok, %{content: %{subject: spanish}}} =
        Catalog.preview(Catalog.get("register"), "es", paths: [])

      refute spanish == "Confirm your account"

      for dialect <- ["es-ES", "es-MX"] do
        assert {:ok, %{content: %{subject: ^spanish}}} =
                 Catalog.preview(Catalog.get("register"), dialect, paths: [])
      end

      assert {:ok, email} =
               UserNotifier.deliver_confirmation_instructions(user("es-ES"), "https://x.test/c")

      assert email.subject == spanish
    end

    test "is rendered in the chosen language" do
      assert {:ok, %{content: %{subject: subject}}} =
               Catalog.preview(Catalog.get("register"), "ru", paths: [])

      refute subject == "Confirm your account"
    end
  end

  describe "preview/3 sources" do
    test "reports a host file with its path, and the group the email names" do
      root = tmp_root()
      subject = write(root, "register/subject.ru.txt", "Файл {{user_email}}\n")
      markdown = write(root, "register/markdown.md", "Hello [Confirm]({{confirmation_url}})")
      write(root, "register/layout.txt", "auth")
      header = write(root, "_header-auth/html.html", "<p>AUTH HEADER</p>")

      assert {:ok, preview} = Catalog.preview(Catalog.get("register"), "ru", paths: [root])

      assert preview.content.subject == "Файл jane.doe@example.com"
      assert preview.content.html =~ "AUTH HEADER"
      assert preview.sources.subject == {:file, subject}
      assert preview.sources.markdown == {:file, markdown}
      assert preview.sources.html_from == :markdown
      assert preview.sources.group == "auth"
      assert preview.sources.header == {:file, header}
      assert preview.sources.footer == :default
    end

    test "lists a placeholder the samples do not bind" do
      root = tmp_root()
      write(root, "register/text.txt", "Hi {{user_email}}, your code is {{code}}")

      assert {:ok, %{missing: %{text: ["code"]}}} =
               Catalog.preview(Catalog.get("register"), "en", paths: [root])
    end

    test "a module entry previews with its own defaults, samples and layout group" do
      entry = hd(EnabledEmailModule.email_templates())

      assert {:ok, preview} = Catalog.preview(entry, "en", paths: [])

      assert preview.content.subject == "Invoice INV-1"
      assert preview.content.html =~ ~s(href="https://pay.example.test/1")
      assert preview.sources.group == "billing"
      assert preview.sources.group_from == :option
    end

    test "an entry whose own function raises, throws or exits answers an error, not a crash" do
      capture_log(fn ->
        entry = %{name: "fixture_broken", label: "Broken", variables: fn -> raise "boom" end}
        assert {:error, "boom"} = Catalog.preview(entry, "en", paths: [])

        entry = %{name: "fixture_broken", label: "Broken", variables: fn -> throw(:nope) end}
        assert {:error, ":nope"} = Catalog.preview(entry, "en", paths: [])

        entry = %{name: "fixture_broken", label: "Broken", defaults: fn -> exit(:gone) end}
        assert {:error, ":gone"} = Catalog.preview(entry, "en", paths: [])
      end)
    end

    test "sample variables and defaults are evaluated in the previewed locale" do
      entry = %{
        name: "fixture_locale",
        label: "Locale",
        defaults: fn -> %{subject: "{{loc}}", text: Gettext.get_locale(PhoenixKitWeb.Gettext)} end,
        variables: fn -> %{"loc" => Gettext.get_locale(PhoenixKitWeb.Gettext)} end
      }

      assert {:ok, %{content: %{subject: "ru", text: "ru"}}} =
               Catalog.preview(entry, "ru", paths: [])
    end
  end

  describe "the send uses the catalog's defaults" do
    defp user(locale) do
      %User{
        uuid: Ecto.UUID.generate(),
        email: "reader@example.test",
        custom_fields: %{"preferred_locale" => locale}
      }
    end

    # What the send must produce if it renders `fun` — so copy that drifts
    # between a send site and CoreTemplates fails here.
    defp expected(name, recipient, variables, fun) do
      Content.resolve(name, recipient, variables, fun)
    end

    test "UserNotifier's emails" do
      u = user("de")
      url = "https://x.test/t"

      cases = [
        {fn -> UserNotifier.deliver_confirmation_instructions(u, url) end, "register",
         %{"user_email" => u.email, "confirmation_url" => url},
         &CoreTemplates.register_defaults/0},
        {fn -> UserNotifier.deliver_reset_password_instructions(u, url) end, "reset_password",
         %{"user_email" => u.email, "reset_url" => url},
         &CoreTemplates.reset_password_defaults/0},
        {fn -> UserNotifier.deliver_update_email_instructions(u, url) end, "update_email",
         %{"user_email" => u.email, "update_url" => url}, &CoreTemplates.update_email_defaults/0},
        {fn -> UserNotifier.deliver_magic_link_registration(u, url) end,
         "magic_link_registration", %{"user_email" => u.email, "registration_url" => url},
         &CoreTemplates.magic_link_registration_defaults/0},
        {fn -> UserNotifier.deliver_failed_login_alert(u, %{count: 4, window_hours: 1}) end,
         "failed_login_alert",
         %{
           "user_email" => u.email,
           "attempt_count" => "4",
           "window_hours" => "1",
           # built in the recipient's locale, as the send builds it
           "security_url" =>
             RecipientLocale.in_locale("de", fn ->
               Routes.base_url() <> Routes.user_settings_path()
             end)
         }, &CoreTemplates.failed_login_alert_defaults/0}
      ]

      for {send, name, variables, fun} <- cases do
        assert {:ok, email} = send.()
        want = expected(name, u, variables, fun)

        assert {email.subject, email.text_body, email.html_body} ==
                 {want.subject, want.text, want.html},
               name
      end
    end

    test "the new login alert" do
      u = user("en")

      attrs = %{
        ip_address: "203.0.113.9",
        browser: "Firefox",
        os: "Linux",
        first_seen_at: ~U[2026-09-30 12:00:00Z]
      }

      assert {:ok, email} = UserNotifier.deliver_new_login_alert(u, attrs)

      # The time is formatted in the reader's zone by the send itself; read it
      # back rather than re-deriving it, and compare everything else.
      [_, login_time] = Regex.run(~r/^- Time: (.+)$/m, email.text_body)

      want =
        expected(
          "new_login_alert",
          u,
          %{
            "user_email" => u.email,
            "login_time" => login_time,
            "ip_address" => "203.0.113.9",
            "location" => "Unknown",
            "browser_os" => "Firefox on Linux",
            "failed_attempts" => "",
            "security_url" => Routes.base_url() <> Routes.user_settings_path()
          },
          &CoreTemplates.new_login_alert_defaults/0
        )

      assert {email.subject, email.text_body, email.html_body} ==
               {want.subject, want.text, want.html}
    end

    test "the organization invitation" do
      url = "https://x.test/o"
      assert {:ok, email} = UserNotifier.deliver_organization_invitation("a@x.test", "Acme", url)

      want =
        expected(
          "organization_invitation",
          "a@x.test",
          %{"user_email" => "a@x.test", "organization_name" => "Acme", "registration_url" => url},
          &CoreTemplates.organization_invitation_defaults/0
        )

      assert {email.subject, email.text_body} == {want.subject, want.text}
    end

    test "the magic link (Mailer's own send)" do
      u = user("en")
      url = "https://x.test/m"
      assert {:ok, _} = Mailer.send_magic_link_email(u, url)

      want =
        expected(
          "magic_link",
          u,
          %{"user_email" => u.email, "magic_link_url" => url},
          &CoreTemplates.magic_link_defaults/0
        )

      assert_email_sent(fn email ->
        assert {email.subject, email.text_body} == {want.subject, want.text}
      end)
    end

    # The send site names the template; a typo there would silently stop a
    # host's files from applying and point the preview's hints at the wrong
    # directory. Each send must pick up an override under its catalog name.
    test "every core send resolves under its catalog name" do
      root = tmp_root()

      for name <- @core_names, do: write(root, "#{name}/subject.txt", "OVERRIDE #{name}")

      previous = Application.get_env(:phoenix_kit, :template_paths)
      Application.put_env(:phoenix_kit, :template_paths, [root])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :template_paths, previous),
          else: Application.delete_env(:phoenix_kit, :template_paths)
      end)

      u = user("en")
      url = "https://x.test/t"
      at = ~U[2026-09-30 12:00:00Z]

      sends = %{
        "register" => fn -> UserNotifier.deliver_confirmation_instructions(u, url) end,
        "reset_password" => fn -> UserNotifier.deliver_reset_password_instructions(u, url) end,
        "update_email" => fn -> UserNotifier.deliver_update_email_instructions(u, url) end,
        "magic_link" => fn -> Mailer.send_magic_link_email(u, url) end,
        "magic_link_registration" => fn ->
          UserNotifier.deliver_magic_link_registration(u, url)
        end,
        "organization_invitation" => fn ->
          UserNotifier.deliver_organization_invitation(u.email, "Acme", url)
        end,
        "new_login_alert" => fn ->
          UserNotifier.deliver_new_login_alert(u, %{ip_address: "1.2.3.4", first_seen_at: at})
        end,
        "failed_login_alert" => fn ->
          UserNotifier.deliver_failed_login_alert(u, %{count: 3, window_hours: 1})
        end,
        "welcome" => fn -> UserNotifier.deliver_welcome(u) end,
        "notification" => fn ->
          {:ok, reader} =
            Auth.register_user(%{
              email: "catalog_reader@example.test",
              password: "ValidPassword123!"
            })

          envelope = %{recipient_uuid: reader.uuid, title: "Hi", text: "Body", url: nil}
          :ok = EmailChannel.deliver(envelope, %{})
          {:ok, :sent}
        end
      }

      assert Enum.sort(Map.keys(sends)) == Enum.sort(@core_names)

      for name <- @core_names do
        assert {:ok, _} = sends[name].()
        expected = "OVERRIDE #{name}"
        assert_email_sent(fn email -> assert email.subject == expected end)
      end
    end

    test "the new login alert's helper lines" do
      assert CoreTemplates.failed_attempts_note(0) == ""
      assert CoreTemplates.failed_attempts_note(1) =~ ~r/1 failed sign-in attempt on/
      assert CoreTemplates.failed_attempts_note(3) =~ ~r/\n\n\z/
      assert CoreTemplates.location_line("Tallinn") == "Tallinn (approximate)"
      assert CoreTemplates.location_line(nil) == "Unknown"

      # every placeholder of the default copy is one the send binds
      assert Templates.missing_variables(
               "new_login_alert",
               CoreTemplates.new_login_alert_defaults(),
               Map.new(
                 ~w(user_email login_time ip_address location browser_os failed_attempts security_url),
                 &{&1, "x"}
               )
             ) == %{}
    end
  end
end
