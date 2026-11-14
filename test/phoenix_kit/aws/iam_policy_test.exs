defmodule PhoenixKit.AWS.IamPolicyTest do
  @moduledoc """
  The policy shown to an operator is built from what the code calls. These
  tests hold the two ends together: what `InfrastructureSetup` declares it
  needs, and the names it creates, against what `IamPolicy` grants.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.AWS.IamPolicy
  alias PhoenixKit.AWS.InfrastructureSetup
  alias PhoenixKit.AWS.SESv2

  doctest PhoenixKit.AWS.IamPolicy
  doctest PhoenixKit.AWS.InfrastructureSetup, only: [project_name: 0, resource_names: 1]

  @opts [project: "Fotki", region: "eu-north-1"]

  defp statement(policy, sid), do: Enum.find(policy["Statement"], &(&1["Sid"] == sid))

  describe "setup/1" do
    test "grants every action the infrastructure setup declares" do
      granted = statement(IamPolicy.setup(@opts), "SetupInfrastructure")["Action"]
      declared = InfrastructureSetup.iam_actions() |> Map.values() |> List.flatten()

      assert Enum.sort(granted) == Enum.sort(declared)
    end

    test "names exactly the resources setup creates, with no wildcard name" do
      names = InfrastructureSetup.resource_names("Fotki")
      resources = statement(IamPolicy.setup(@opts), "SetupInfrastructure")["Resource"]

      assert resources == [
               "arn:aws:ses:eu-north-1:*:configuration-set/#{names.configuration_set}",
               "arn:aws:sns:eu-north-1:*:#{names.topic}",
               "arn:aws:sqs:eu-north-1:*:#{names.queue}",
               "arn:aws:sqs:eu-north-1:*:#{names.dlq}"
             ]

      # The only `*` in an ARN is the account.
      for arn <- resources do
        assert arn |> String.split(":") |> Enum.count(&(&1 == "*")) == 1
        refute String.ends_with?(arn, "*")
      end
    end

    test "grants no List or Describe action: nothing calls one" do
      actions = IamPolicy.setup(@opts)["Statement"] |> Enum.flat_map(& &1["Action"])

      refute Enum.any?(actions, &(&1 =~ ~r/:(List|Describe|DeleteQueue|DeleteTopic)/))
      refute Enum.any?(actions, &String.ends_with?(&1, "*"))
    end
  end

  describe "running/1" do
    test "is the setup policy without the SetupInfrastructure statement" do
      setup = IamPolicy.setup(@opts)
      running = IamPolicy.running(@opts)

      assert running["Statement"] ==
               Enum.reject(setup["Statement"], &(&1["Sid"] == "SetupInfrastructure"))

      assert Enum.map(running["Statement"], & &1["Sid"]) == ["Send", "ReadDeliveryEvents"]
    end

    test "reads the queue and the dead-letter queue, and nothing else of SQS" do
      events = statement(IamPolicy.running(@opts), "ReadDeliveryEvents")

      assert events["Action"] == ["sqs:ReceiveMessage", "sqs:DeleteMessage"]

      assert events["Resource"] == [
               "arn:aws:sqs:eu-north-1:*:fotki-email-queue",
               "arn:aws:sqs:eu-north-1:*:fotki-email-dlq"
             ]
    end

    test "sending is on every resource: a send is authorised against the identity" do
      send = statement(IamPolicy.running(@opts), "Send")

      assert send["Resource"] == "*"
      assert "ses:SendRawEmail" in send["Action"]
      assert "ses:SendEmail" in send["Action"]
      assert "ses:GetSendQuota" in send["Action"]
    end
  end

  describe "sending/0" do
    test "is the Send statement alone" do
      assert [%{"Sid" => "Send"} = send] = IamPolicy.sending()["Statement"]
      assert send == statement(IamPolicy.running(@opts), "Send")
    end
  end

  describe "the names follow the project title" do
    test "the same titles give the same names in the policy and in setup" do
      for title <- ["Fotki", "My App!", "myapp", "Фотки", ""] do
        names = InfrastructureSetup.resource_names(title)
        text = IamPolicy.json(IamPolicy.setup(project: title, region: "eu-west-1"))

        for {_kind, name} <- names do
          assert text =~ name
        end
      end
    end

    test "a blank region leaves a placeholder instead of an invalid ARN" do
      for region <- [nil, "", "  "] do
        assert IamPolicy.json(IamPolicy.running(project: "Fotki", region: region)) =~
                 "arn:aws:sqs:<region>:*:fotki-email-queue"
      end
    end

    test "saved names win over the title" do
      tracking = %{
        "queue_arn" => "arn:aws:sqs:eu-north-1:123456789012:old-email-queue",
        "dlq_url" => "https://sqs.eu-north-1.amazonaws.com/123456789012/old-email-dlq",
        "sns_topic_arn" => "arn:aws:sns:eu-north-1:123456789012:old-email-events",
        "configuration_set" => "old-emailing",
        "region" => "eu-north-1"
      }

      names = IamPolicy.names_from_tracking(tracking)

      assert names == %{
               queue: "old-email-queue",
               dlq: "old-email-dlq",
               topic: "old-email-events",
               configuration_set: "old-emailing"
             }

      text =
        IamPolicy.json(IamPolicy.setup(project: "Renamed", region: "eu-north-1", names: names))

      assert text =~ "old-email-queue"
      assert text =~ "configuration-set/old-emailing"
      refute text =~ "renamed"
    end

    test "the tracking row is read with atom keys too, as the emails package holds it" do
      names =
        IamPolicy.names_from_tracking(%{
          queue_arn: "arn:aws:sqs:eu-north-1:1:old-email-queue",
          dlq_url: "https://sqs.eu-north-1.amazonaws.com/1/old-email-dlq",
          sns_topic_arn: "arn:aws:sns:eu-north-1:1:old-email-events",
          configuration_set: "old-emailing",
          region: "eu-north-1"
        })

      assert names.queue == "old-email-queue"
      assert names.dlq == "old-email-dlq"
    end

    test "a half-filled tracking row gives no names, so the title is used" do
      assert IamPolicy.names_from_tracking(%{"queue_arn" => "arn:aws:sqs:r:1:q"}) == nil
      assert IamPolicy.names_from_tracking(%{}) == nil
      assert IamPolicy.names_from_tracking(nil) == nil

      assert IamPolicy.json(IamPolicy.running(project: "Fotki", region: "r", names: nil)) =~
               "fotki-email-queue"
    end
  end

  describe "json/1" do
    test "is valid JSON that decodes back to the policy" do
      for policy <- [IamPolicy.setup(@opts), IamPolicy.running(@opts), IamPolicy.sending()] do
        assert JSON.decode!(IamPolicy.json(policy)) == policy
      end
    end

    test "prints the keys in the order AWS does" do
      text = IamPolicy.json(IamPolicy.sending())

      assert text == """
             {
               "Version": "2012-10-17",
               "Statement": [
                 {
                   "Sid": "Send",
                   "Effect": "Allow",
                   "Action": [
                     "ses:SendRawEmail",
                     "ses:SendEmail",
                     "ses:GetSendQuota"
                   ],
                   "Resource": "*"
                 }
               ]
             }\
             """
    end
  end

  describe "InfrastructureSetup.project_name/1" do
    test "a title that leaves nothing falls back to the default name" do
      assert InfrastructureSetup.project_name("Фотки") == "myapp"
      assert InfrastructureSetup.project_name("!!!") == "myapp"
      assert InfrastructureSetup.project_name("") == "myapp"
      assert InfrastructureSetup.project_name(nil) == "myapp"
    end

    test "is stable when applied twice" do
      for title <- ["My App!", "Fotki", "a--b", "Фотки 2"] do
        once = InfrastructureSetup.project_name(title)
        assert InfrastructureSetup.project_name(once) == once
      end
    end
  end

  describe "InfrastructureSetup.access_denied?/1" do
    test "recognises AWS refusing a permission, in both shapes it arrives in" do
      assert InfrastructureSetup.access_denied?(
               ~s({:http_error, 403, %{body: "<Code>AccessDenied</Code>"}})
             )

      assert InfrastructureSetup.access_denied?(
               "User: arn:aws:iam::1:user/x is not authorized to perform: ses:CreateConfigurationSet"
             )

      # SNS names it AuthorizationError, not AccessDenied (seen on a real account).
      assert InfrastructureSetup.access_denied?(
               ~s({:http_error, 403, %{code: "AuthorizationError", message: "User: arn:aws:iam::1:user/x is not authorized to perform: SNS:Subscribe on resource: arn:aws:sns:eu-north-1:1:t"}})
             )

      refute InfrastructureSetup.access_denied?("Could not parse account ID")
      refute InfrastructureSetup.access_denied?(nil)
    end
  end

  describe "SESv2.event_types/1" do
    test "opens and clicks are published only when asked for" do
      refute "OPEN" in SESv2.event_types()
      refute "CLICK" in SESv2.event_types(false)
      assert length(SESv2.event_types(false)) == 8

      assert "OPEN" in SESv2.event_types(true)
      assert "CLICK" in SESv2.event_types(true)
      assert SESv2.event_types(true) -- SESv2.event_types(false) == ["OPEN", "CLICK"]
    end
  end

  # The guide cannot call the module, so it carries the text. This is what
  # keeps the two from drifting: every earlier copy of the policy did.
  describe "guides/aws-email-setup.md" do
    @guide File.read!("guides/aws-email-setup.md")
    @external_resource "guides/aws-email-setup.md"

    @placeholder_names %{
      queue: "<project>-email-queue",
      dlq: "<project>-email-dlq",
      topic: "<project>-email-events",
      configuration_set: "<project>-emailing"
    }

    test "prints the three policies exactly as the module builds them" do
      for policy <- [
            IamPolicy.setup(names: @placeholder_names),
            IamPolicy.running(names: @placeholder_names),
            IamPolicy.sending()
          ] do
        assert @guide =~ "```json\n" <> IamPolicy.json(policy) <> "\n```"
      end
    end

    test "carries no other policy document" do
      assert @guide |> String.split("```json") |> length() == 4
    end

    test "names every action of the setup policy in its table" do
      actions =
        IamPolicy.setup(names: @placeholder_names)["Statement"] |> Enum.flat_map(& &1["Action"])

      [_before, table] = String.split(@guide, "### What each permission is for", parts: 2)
      [table, _after] = String.split(table, "## Step by step", parts: 2)

      for action <- actions -- ["ses:SendEmail"] do
        assert table =~ "`#{action}`"
      end
    end
  end
end
