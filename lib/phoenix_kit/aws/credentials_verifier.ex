defmodule PhoenixKit.AWS.CredentialsVerifier do
  @moduledoc """
  Checks that an AWS key pair is real and says whose it is.

  `verify_credentials/3` validates the format of the pair and calls AWS STS
  `GetCallerIdentity`, which AWS allows to every key. It answers the account
  id, the user id and the ARN.

  It does not ask what the key may do. The permissions a key needs are listed
  by `PhoenixKit.AWS.IamPolicy`, and whether it has them shows where they are
  used: the infrastructure setup and the event poller.

  ## Usage

      PhoenixKit.AWS.CredentialsVerifier.verify_credentials(
        "AKIA...",
        "****************",
        "eu-north-1"
      )
  """

  alias ExAws.STS

  @doc """
  Verifies AWS credentials using STS GetCallerIdentity.

  ## Parameters

    - `access_key_id`: AWS Access Key ID (string)
    - `secret_access_key`: AWS Secret Access Key (string)
    - `region`: AWS region (string)

  ## Returns

    - `{:ok, %{access_key_id: string, aws_user_id: string, account_id: string, arn: string}}` on success
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
         {:parse, {:ok, aws_user_id, account_id, arn}} <- {:parse, parse_sts_response(body)} do
      {:ok,
       %{
         access_key_id: access_key_id,
         aws_user_id: aws_user_id,
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

  # Handle already parsed map response from ExAws (modern behavior)
  defp parse_sts_response(body) when is_map(body) do
    # ExAws automatically parses the XML response into a map
    # Structure: %{user_id: "...", account: "...", arn: "..."}
    with {:aws_user_id, aws_user_id} when is_binary(aws_user_id) <-
           {:aws_user_id, Map.get(body, :user_id)},
         {:account, account} when is_binary(account) <- {:account, Map.get(body, :account)},
         {:arn, arn} when is_binary(arn) <- {:arn, Map.get(body, :arn)} do
      {:ok, aws_user_id, account, arn}
    else
      {:aws_user_id, _} -> {:error, "Missing or invalid user_id in STS response"}
      {:account, _} -> {:error, "Missing or invalid account in STS response"}
      {:arn, _} -> {:error, "Missing or invalid arn in STS response"}
    end
  rescue
    e ->
      {:error, "Map parsing error: #{inspect(e)}"}
  end

  # Handle XML string response (legacy/fallback)
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
         {:ok, aws_user_id} <- extract_xml_value(body, "UserId"),
         {:ok, account_id} <- extract_xml_value(body, "Account"),
         {:ok, arn} <- extract_xml_value(body, "Arn") do
      {:ok, aws_user_id, account_id, arn}
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
end
