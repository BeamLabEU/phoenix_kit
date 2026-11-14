defmodule PhoenixKit.AWS.IamPolicy do
  @moduledoc """
  The IAM policy an Amazon SES key needs, built from what the code calls.

  There are two, used one after the other:

    * `setup/1` - attached while the delivery-event infrastructure is being
      created (`PhoenixKit.AWS.InfrastructureSetup.run/1`). It sends, creates
      the queues, the topic and the configuration set, and reads the queues.
    * `running/1` - what the key keeps afterwards: it sends and reads the
      queues. It is `setup/1` without the `SetupInfrastructure` statement, so
      the key left on the server cannot create or reconfigure anything.

  A key that only sends, with no delivery events, needs `sending/0`: the
  `Send` statement alone. `running/1` is also correct for it.

  Every place that shows a policy (the Amazon SES connection form, the email
  settings, the guide) takes it from here, and the resource names come from
  `PhoenixKit.AWS.InfrastructureSetup.resource_names/1`, which setup itself
  uses. The two therefore cannot drift apart.

  ## Options

    * `:project` - the project title or name the resources are named from.
      Default: the site's (`InfrastructureSetup.project_name/0`).
    * `:region` - the AWS region. Blank gives the placeholder `<region>`.
    * `:names` - the resource names to use instead of the ones derived from
      `:project`: a map with `:queue`, `:dlq`, `:topic` and
      `:configuration_set`. Pass what setup saved (`names_from_tracking/1`),
      so a site whose title changed since still gets a policy that matches
      its real queues.

  ## Example

      iex> policy = PhoenixKit.AWS.IamPolicy.running(project: "Fotki", region: "eu-north-1")
      iex> Enum.map(policy["Statement"], & &1["Sid"])
      ["Send", "ReadDeliveryEvents"]
  """

  alias PhoenixKit.AWS.InfrastructureSetup

  @region_placeholder "<region>"

  # `Swoosh.Adapters.AmazonSES` sends with SendRawEmail and
  # `PhoenixKit.Integrations.Validators` tests a connection with GetSendQuota.
  # SendEmail is not called: it is what the SES v2 API sends with, kept so a
  # move to it breaks no installed key. GetSendQuota takes no resource and a
  # send is authorised against the sending identity, hence "*".
  @send_actions ["ses:SendRawEmail", "ses:SendEmail", "ses:GetSendQuota"]

  # The poller of `phoenix_kit_emails` (`SQSPollingJob`, `Emails`): it
  # receives from the queue and the dead-letter queue and deletes what it has
  # processed.
  @event_actions ["sqs:ReceiveMessage", "sqs:DeleteMessage"]

  @type policy :: %{String.t() => term()}

  @doc "The policy for the time the infrastructure is being set up."
  @spec setup(keyword()) :: policy()
  def setup(opts \\ []) do
    arns = arns(opts)
    policy([send_statement(), setup_statement(arns), events_statement(arns)])
  end

  @doc "The policy the key keeps once the infrastructure exists."
  @spec running(keyword()) :: policy()
  def running(opts \\ []) do
    policy([send_statement(), events_statement(arns(opts))])
  end

  @doc "The policy of a key that only sends: no setup, no delivery events."
  @spec sending() :: policy()
  def sending, do: policy([send_statement()])

  @doc """
  The resource names saved by a finished setup, in the shape `:names` takes.

  Reads the tracking map the emails package stores per account (`queue_arn`,
  `dlq_url`, `sns_topic_arn`, `configuration_set`). Answers `nil` unless all
  four are there, so a half-filled row falls back to the derived names.
  """
  @spec names_from_tracking(term()) :: map() | nil
  def names_from_tracking(%{} = tracking) do
    names = %{
      queue: last_segment(tracking["queue_arn"], ":"),
      dlq: last_segment(tracking["dlq_url"], "/"),
      topic: last_segment(tracking["sns_topic_arn"], ":"),
      configuration_set: last_segment(tracking["configuration_set"], "/")
    }

    if Enum.all?(Map.values(names), &is_binary/1), do: names
  end

  def names_from_tracking(_tracking), do: nil

  @doc """
  A policy as indented JSON, ready to paste into the AWS console.

  The keys keep the order AWS itself prints them in.
  """
  @spec json(policy()) :: String.t()
  def json(%{"Version" => version, "Statement" => statements}) do
    body = Enum.map_join(statements, ",\n", &statement_json/1)

    """
    {
      "Version": #{JSON.encode!(version)},
      "Statement": [
    #{body}
      ]
    }
    """
    |> String.trim_trailing()
  end

  # --- statements -----------------------------------------------------------

  defp policy(statements), do: %{"Version" => "2012-10-17", "Statement" => statements}

  defp send_statement do
    %{"Sid" => "Send", "Effect" => "Allow", "Action" => @send_actions, "Resource" => "*"}
  end

  defp setup_statement(arns) do
    actions = InfrastructureSetup.iam_actions()

    %{
      "Sid" => "SetupInfrastructure",
      "Effect" => "Allow",
      "Action" => actions.configuration_set ++ actions.topic ++ actions.queue,
      "Resource" => [arns.configuration_set, arns.topic, arns.queue, arns.dlq]
    }
  end

  defp events_statement(arns) do
    %{
      "Sid" => "ReadDeliveryEvents",
      "Effect" => "Allow",
      "Action" => @event_actions,
      "Resource" => [arns.queue, arns.dlq]
    }
  end

  # The account is left open (`*`): the key only ever acts in its own.
  defp arns(opts) do
    region = region(Keyword.get(opts, :region))
    names = names(opts)

    %{
      configuration_set: "arn:aws:ses:#{region}:*:configuration-set/#{names.configuration_set}",
      topic: "arn:aws:sns:#{region}:*:#{names.topic}",
      queue: "arn:aws:sqs:#{region}:*:#{names.queue}",
      dlq: "arn:aws:sqs:#{region}:*:#{names.dlq}"
    }
  end

  defp names(opts) do
    case Keyword.get(opts, :names) do
      %{queue: _, dlq: _, topic: _, configuration_set: _} = names ->
        names

      _ ->
        case Keyword.fetch(opts, :project) do
          {:ok, project} -> InfrastructureSetup.resource_names(project)
          :error -> InfrastructureSetup.resource_names(InfrastructureSetup.project_name())
        end
    end
  end

  defp region(region) when is_binary(region) do
    case String.trim(region) do
      "" -> @region_placeholder
      trimmed -> trimmed
    end
  end

  defp region(_region), do: @region_placeholder

  defp last_segment(value, separator) when is_binary(value) do
    case value |> String.trim() |> String.split(separator) |> List.last() do
      "" -> nil
      segment -> segment
    end
  end

  defp last_segment(_value, _separator), do: nil

  # --- JSON -----------------------------------------------------------------

  defp statement_json(statement) do
    fields =
      for key <- ["Sid", "Effect", "Action", "Resource"], Map.has_key?(statement, key) do
        "      #{JSON.encode!(key)}: #{value_json(statement[key])}"
      end

    "    {\n" <> Enum.join(fields, ",\n") <> "\n    }"
  end

  defp value_json(values) when is_list(values) do
    items = Enum.map_join(values, ",\n", &("        " <> JSON.encode!(&1)))
    "[\n" <> items <> "\n      ]"
  end

  defp value_json(value), do: JSON.encode!(value)
end
