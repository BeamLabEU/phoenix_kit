defmodule PhoenixKit.AWS.CredentialsVerifier do
  @moduledoc """
  AWS credentials verification module.

  This module provides functionality to:
  - Validate AWS Access Key ID and Secret Access Key format
  - Verify credential connectivity via AWS STS GetCallerIdentity
  - List available AWS regions
  - Check minimal required permissions for email operations

  ## Features

  - **Credential Validation**: Basic format validation for access key and secret
  - **Connectivity Testing**: Verify credentials can make AWS API calls
  - **Region Discovery**: List available regions for the AWS account
  - **Permission Checks**: Validate access to SQS, SNS, and SES services
  - **Error Handling**: Detailed error messages for common issues

  ## Usage

      # Basic credential verification
      PhoenixKit.AWS.CredentialsVerifier.verify_credentials(
        access_key_id: "AKIA...",
        secret_access_key: "****************",
        region: "eu-north-1"
      )

      # Get available regions
      PhoenixKit.AWS.CredentialsVerifier.get_available_regions(
        access_key_id: "AKIA...",
        secret_access_key: "****************",
        region: "eu-north-1"
      )
  """

  require Logger

  alias ExAws.{EC2, SNS, SQS, STS}

  # Note: SES не имеет ExAws библиотеки, будем использовать прямые HTTP вызовы через ExAws.Operation.Query

  @doc """
  Verifies AWS credentials using STS GetCallerIdentity.

  ## Parameters

    - `access_key_id`: AWS Access Key ID (string)
    - `secret_access_key`: AWS Secret Access Key (string)
    - `region`: AWS region (string)

  ## Returns

    - `{:ok, %{access_key_id: string, user_id: string, account_id: string, arn: string}}` on success
    - `{:error, :invalid_credentials}` for format issues
    - `{:error, :authentication_failed}` for invalid credentials
    - `{:error, :network_error}` for connectivity issues
    - `{:error, rate_limited}` for AWS rate limiting
  """
  def verify_credentials(access_key_id, secret_access_key, region) do
    # Validate credential format first
    with {:format_ok, true} <-
           {:format_ok, validate_credentials_format(access_key_id, secret_access_key)},
         {:config, {:ok, config}} <-
           {:config, create_config(access_key_id, secret_access_key, region)},
         {:sts_call, {:ok, %{body: body}}} <-
           {:sts_call, STS.get_caller_identity() |> ExAws.request(config)},
         {:parse, {:ok, user_id, account_id, arn}} <- {:parse, parse_sts_response(body)} do
      {:ok,
       %{
         access_key_id: access_key_id,
         user_id: user_id,
         account_id: account_id,
         arn: arn
       }}
    else
      {:format_ok, false} ->
        {:error, :invalid_credentials,
         "Invalid credential format. Access key should be 20 characters, secret key should not be empty."}

      {:config, {:error, reason}} ->
        {:error, :configuration_error, "Failed to create AWS configuration: #{inspect(reason)}"}

      {:sts_call, {:error, %{status_code: 403}}} ->
        {:error, :authentication_failed,
         "AWS authentication failed. Please check your access key and secret key."}

      {:sts_call, {:error, %{status_code: 404}}} ->
        {:error, :authentication_failed,
         "AWS authentication failed. Region not found or incorrect."}

      {:sts_call, {:error, %{status_code: 429}}} ->
        {:error, :rate_limited, "AWS API rate limit exceeded. Please try again later."}

      {:sts_call, {:error, reason}} ->
        {:error, :network_error, "Network or AWS API error: #{inspect(reason)}"}

      {:parse, {:error, reason}} ->
        {:error, :response_error, "Failed to parse AWS response: #{reason}"}
    end
  end

  @doc """
  Gets list of available AWS regions for the account.

  ## Parameters

    - `access_key_id`: AWS Access Key ID (string)
    - `secret_access_key`: AWS Secret Access Key (string)
    - `region`: AWS region (string)

  ## Returns

    - `{:ok, [region_names]}` on success
    - `{:error, reason}` on failure
  """
  def get_available_regions(access_key_id, secret_access_key, region) do
    case create_config(access_key_id, secret_access_key, region) do
      {:ok, config} ->
        # Try to get regions from EC2 API first
        case get_regions_from_ec2(config) do
          {:ok, regions} when is_list(regions) and length(regions) > 0 ->
            {:ok, regions}

          {:error, :permission_denied} ->
            # EC2 permission missing - fallback to common regions
            Logger.warning(
              "EC2 DescribeRegions permission missing. Using common regions list. " <>
                "Add 'ec2:DescribeRegions' to IAM policy for accurate region list."
            )

            {:ok, list_common_regions(nil)}

          {:error, reason} ->
            # Other error - also fallback but log error
            Logger.error(
              "Failed to get regions from EC2 API: #{inspect(reason)}. Using fallback."
            )

            {:ok, list_common_regions(nil)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private function to get regions from EC2 API
  defp get_regions_from_ec2(config) do
    case EC2.describe_regions() |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        parse_ec2_regions(body)

      {:error, {:http_error, 403, _}} ->
        {:error, :permission_denied}

      {:error, %{status_code: 403}} ->
        {:error, :permission_denied}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Exception in EC2 describe_regions: #{inspect(e)}")
      {:error, :ec2_api_error}
  end

  # Parse EC2 DescribeRegions response
  defp parse_ec2_regions(body) when is_map(body) do
    # ExAws parses XML to map structure
    # Response structure: %{regions_set: [%{region_name: "us-east-1", ...}, ...]}
    regions =
      body
      |> Map.get(:regions_set, [])
      |> Enum.map(fn region -> Map.get(region, :region_name) end)
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    if length(regions) > 0 do
      {:ok, regions}
    else
      {:error, :empty_regions_list}
    end
  rescue
    e ->
      Logger.error("Failed to parse EC2 regions response: #{inspect(e)}")
      {:error, :parse_error}
  end

  defp parse_ec2_regions(_body) do
    {:error, :invalid_response_format}
  end

  @doc """
  Validates minimum permissions required for email operations.

  Checks specific AWS permissions needed for "Setup AWS Infrastructure" script:
  - SQS: CreateQueue, GetQueueAttributes, SetQueueAttributes
  - SNS: CreateTopic, Subscribe, SetTopicAttributes
  - SES: CreateConfigurationSet, DescribeConfigurationSet
  - EC2: DescribeRegions (optional)

  ## Parameters

    - `access_key_id`: AWS Access Key ID (string)
    - `secret_access_key`: AWS Secret Access Key (string)
    - `region`: AWS region (string)

  ## Returns

    - `{:ok, permissions_map}` where permissions_map is:
      ```
      %{
        sqs: %{
          "CreateQueue" => :granted | :denied | :unknown,
          "GetQueueAttributes" => :granted | :denied | :unknown,
          "SetQueueAttributes" => :granted | :denied | :unknown
        },
        sns: %{...},
        ses: %{...},
        ec2: %{...}
      }
      ```
    - `{:error, reason}` if configuration fails
  """
  def check_permissions(access_key_id, secret_access_key, region) do
    case create_config(access_key_id, secret_access_key, region) do
      {:ok, config} ->
        permissions = %{
          sqs: check_sqs_permissions(config),
          sns: check_sns_permissions(config),
          ses: check_ses_permissions(config, region),
          ec2: check_ec2_permissions(config)
        }

        {:ok, permissions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Check SQS permissions
  defp check_sqs_permissions(config) do
    %{
      "CreateQueue" => check_sqs_create_queue(config),
      "GetQueueAttributes" => check_sqs_get_queue_attributes(config),
      "SetQueueAttributes" => check_sqs_set_queue_attributes(config)
    }
  end

  # Check SNS permissions
  defp check_sns_permissions(config) do
    %{
      "CreateTopic" => check_sns_create_topic(config),
      "Subscribe" => check_sns_subscribe(config),
      "SetTopicAttributes" => check_sns_set_topic_attributes(config)
    }
  end

  # Check SES permissions
  defp check_ses_permissions(config, region) do
    %{
      "CreateConfigurationSet" => check_ses_create_configuration_set(config, region),
      "DescribeConfigurationSet" => check_ses_describe_configuration_set(config, region)
    }
  end

  # Check EC2 permissions
  defp check_ec2_permissions(config) do
    %{
      "DescribeRegions" => check_ec2_describe_regions(config)
    }
  end

  # SQS permission checks
  defp check_sqs_create_queue(config) do
    # Try to list queues - if we can list, we can likely create
    case SQS.list_queues() |> ExAws.request(config) do
      {:ok, _} -> :granted
      {:error, {:http_error, 403, _}} -> :denied
      {:error, %{status_code: 403}} -> :denied
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp check_sqs_get_queue_attributes(_config) do
    # Cannot check without existing queue - assume granted if list_queues works
    :unknown
  end

  defp check_sqs_set_queue_attributes(_config) do
    # Cannot check without existing queue - assume granted if list_queues works
    :unknown
  end

  # SNS permission checks
  defp check_sns_create_topic(config) do
    # Try to list topics - if we can list, we can likely create
    case SNS.list_topics() |> ExAws.request(config) do
      {:ok, _} -> :granted
      {:error, {:http_error, 403, _}} -> :denied
      {:error, %{status_code: 403}} -> :denied
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp check_sns_subscribe(_config) do
    # Cannot check without existing topic - assume granted if list_topics works
    :unknown
  end

  defp check_sns_set_topic_attributes(_config) do
    # Cannot check without existing topic - assume granted if list_topics works
    :unknown
  end

  # SES permission checks
  defp check_ses_create_configuration_set(config, region) do
    # Try to list configuration sets
    case call_ses_api("ListConfigurationSets", %{}, config, region) do
      {:ok, _} -> :granted
      {:error, {:http_error, 403, _}} -> :denied
      {:error, %{status_code: 403}} -> :denied
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp check_ses_describe_configuration_set(config, region) do
    # Same as create - use list operation
    check_ses_create_configuration_set(config, region)
  end

  # EC2 permission checks
  defp check_ec2_describe_regions(config) do
    case EC2.describe_regions() |> ExAws.request(config) do
      {:ok, _} -> :granted
      {:error, {:http_error, 403, _}} -> :denied
      {:error, %{status_code: 403}} -> :denied
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Helper to call SES API directly (ExAws doesn't have SES module)
  defp call_ses_api(action, params, config, region) do
    operation = %ExAws.Operation.Query{
      path: "/",
      params:
        params
        |> Map.put("Action", action)
        |> Map.put("Version", "2010-12-01"),
      service: :email,
      action: action,
      parser: &ExAws.Utils.identity/2
    }

    ExAws.request(operation, Keyword.put(config, :region, region))
  end

  # Private helper functions

  defp validate_credentials_format(access_key_id, secret_access_key) do
    access_key_valid? = String.length(String.trim(access_key_id)) == 20
    secret_key_valid? = String.length(String.trim(secret_access_key)) > 0
    access_key_valid? and secret_key_valid?
  end

  defp create_config(access_key_id, secret_access_key, region) do
    config = [
      access_key_id: String.trim(access_key_id),
      secret_access_key: String.trim(secret_access_key),
      region: String.trim(region)
    ]

    {:ok, config}
  rescue
    e ->
      {:error, "Failed to create config: #{inspect(e)}"}
  end

  defp parse_sts_response(body) when is_binary(body) do
    # Parse XML response from STS
    # Example structure:
    # <GetCallerIdentityResponse>
    #   <GetCallerIdentityResult>
    #     <UserId>AIDACKEVSAMPLE...</UserId>
    #     <Account>123456789012</Account>
    #     <Arn>arn:aws:sts::123456789012:assumed-role/...</Arn>
    #   </GetCallerIdentityResult>
    # </GetCallerIdentityResponse>

    with true <- String.contains?(body, "<UserId>"),
         {:ok, user_id} <- extract_xml_value(body, "UserId"),
         {:ok, account_id} <- extract_xml_value(body, "Account"),
         {:ok, arn} <- extract_xml_value(body, "Arn") do
      {:ok, user_id, account_id, arn}
    else
      false -> {:error, "Could not find UserId in STS response"}
      {:error, _} -> {:error, "Could not parse all required fields from STS response"}
    end
  rescue
    e ->
      {:error, "XML parsing error: #{inspect(e)}"}
  end

  defp parse_sts_response(_body) do
    {:error, "Invalid STS response format"}
  end

  # Helper to extract XML tag value
  defp extract_xml_value(body, tag_name) do
    open_tag = "<#{tag_name}>"
    close_tag = "</#{tag_name}>"

    case String.split(body, open_tag) do
      [_, rest] ->
        case String.split(rest, close_tag) do
          [value, _] -> {:ok, String.trim(value)}
          _ -> {:error, :tag_not_closed}
        end

      _ ->
        {:error, :tag_not_found}
    end
  end

  defp list_common_regions(_account_id) do
    # List of commonly used AWS regions. In a production environment,
    # you would call EC2 DescribeRegions API to get actual regions for the account.
    [
      "us-east-1",
      "us-east-2",
      "us-west-1",
      "us-west-2",
      "af-south-1",
      "ap-east-1",
      "ap-northeast-1",
      "ap-northeast-2",
      "ap-northeast-3",
      "ap-south-1",
      "ap-southeast-1",
      "ap-southeast-2",
      "ca-central-1",
      "eu-central-1",
      "eu-north-1",
      "eu-south-1",
      "eu-south-2",
      "eu-west-1",
      "eu-west-2",
      "eu-west-3",
      "me-south-1",
      "sa-east-1"
    ]
  end
end
