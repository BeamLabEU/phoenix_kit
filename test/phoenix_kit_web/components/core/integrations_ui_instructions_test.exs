defmodule PhoenixKitWeb.Components.Core.IntegrationsUIInstructionsTest do
  @moduledoc """
  `setup_instructions/1` picks its sections by `scope`. A caller that names no
  scope is a personal page (the surface that predates the site/personal split),
  so it must not show the sections written for the admin.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.IntegrationsUI

  @provider %{
    instructions: [
      %{title: "For the admin", scopes: [:system], steps: [{"admin step", nil}]},
      %{title: "For the user", scopes: [:personal], steps: [{"user step", nil}]},
      %{title: "For everyone", steps: [{"shared step", nil}]}
    ]
  }

  test "no scope means the personal sections" do
    html = render_component(&IntegrationsUI.setup_instructions/1, provider: @provider)

    assert html =~ "For the user"
    assert html =~ "For everyone"
    refute html =~ "For the admin"
  end

  test "the system scope shows the admin sections instead" do
    html =
      render_component(&IntegrationsUI.setup_instructions/1,
        provider: @provider,
        scope: :system
      )

    assert html =~ "For the admin"
    assert html =~ "For everyone"
    refute html =~ "For the user"
  end

  test "renders no card when every section is for the other surface" do
    provider = %{instructions: [%{title: "Admin only", scopes: [:system], steps: []}]}

    html = render_component(&IntegrationsUI.setup_instructions/1, provider: provider)

    refute html =~ "<details"
    refute html =~ "Admin only"
  end

  describe "a section with policies" do
    alias PhoenixKit.Integrations.Providers

    test "the site form of Amazon SES shows the setup and the running policy" do
      html =
        render_component(&IntegrationsUI.setup_instructions/1,
          provider: Providers.get("aws_ses"),
          scope: :system,
          region: "eu-north-1"
        )

      assert html =~ ~s(id="aws-ses-policy-setup")
      assert html =~ ~s(id="aws-ses-policy-running")
      refute html =~ ~s(id="aws-ses-policy-sending")

      assert html =~ "SetupInfrastructure"
      assert html =~ "arn:aws:sqs:eu-north-1:*:"
      assert html =~ "-email-queue"
      refute html =~ "&lt;region&gt;"
    end

    test "a personal connection gets the sending policy only" do
      html =
        render_component(&IntegrationsUI.setup_instructions/1,
          provider: Providers.get("aws_ses"),
          scope: :personal
        )

      assert html =~ ~s(id="aws-ses-policy-sending")
      refute html =~ ~s(id="aws-ses-policy-setup")
      refute html =~ "SetupInfrastructure"
      refute html =~ "sqs:"
    end

    test "with no region saved the placeholder stays and the reader is told" do
      html =
        render_component(&IntegrationsUI.setup_instructions/1,
          provider: Providers.get("aws_ses"),
          scope: :system
        )

      assert html =~ "arn:aws:sqs:&lt;region&gt;:*:"
      assert html =~ "No region is saved"
    end

    test "the instructions name no permission that nothing calls" do
      html =
        render_component(&IntegrationsUI.setup_instructions/1,
          provider: Providers.get("aws_ses"),
          scope: :system,
          region: "eu-north-1"
        )

      for stale <- [
            "ListQueues",
            "ListTopics",
            "ListConfigurationSets",
            "DescribeRegions",
            "ses:*"
          ] do
        refute html =~ stale
      end
    end

    test "saved names and an id of the caller's replace the derived ones" do
      html =
        render_component(&IntegrationsUI.aws_ses_policies/1,
          policies: [:running],
          region: "eu-north-1",
          id: "account-1-policy",
          names: %{
            queue: "old-email-queue",
            dlq: "old-email-dlq",
            topic: "old-email-events",
            configuration_set: "old-emailing"
          }
        )

      assert html =~ ~s(id="account-1-policy-running")
      assert html =~ "arn:aws:sqs:eu-north-1:*:old-email-queue"
      refute html =~ "SetupInfrastructure"
    end
  end
end
