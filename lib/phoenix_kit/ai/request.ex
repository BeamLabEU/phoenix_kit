defmodule PhoenixKit.AI.Request do
  @moduledoc """
  AI request schema for PhoenixKit AI system.

  Tracks every AI API request for usage history and statistics.
  Used for monitoring costs, performance, and debugging.

  ## Schema Fields

  ### Request Identity
  - `endpoint_id`: Foreign key to the AI endpoint used (new system)
  - `endpoint_name`: Denormalized endpoint name for historical display
  - `account_id`: Foreign key to AI account (deprecated, for backward compatibility)
  - `user_id`: Foreign key to the user who made the request (nullable if user deleted)
  - `slot_index`: Which slot was used (deprecated, for backward compatibility)

  ### Request Details
  - `model`: Model identifier (e.g., "anthropic/claude-3-haiku")
  - `request_type`: Type of request (e.g., "text_completion", "chat")

  ### Token Usage
  - `input_tokens`: Number of tokens in the prompt
  - `output_tokens`: Number of tokens in the response
  - `total_tokens`: Total tokens used (input + output)

  ### Performance & Cost
  - `cost_cents`: Estimated cost in cents (when available)
  - `latency_ms`: Response time in milliseconds
  - `status`: Request status - "success", "error", or "timeout"
  - `error_message`: Error details if status is not "success"

  ### Metadata
  - `metadata`: Additional context (temperature, max_tokens, etc.)

  ## Status Types

  - `success` - Request completed successfully
  - `error` - Request failed with an error
  - `timeout` - Request timed out

  ## Usage Examples

      # Log a successful request (new endpoint system)
      {:ok, request} = PhoenixKit.AI.create_request(%{
        endpoint_id: 1,
        endpoint_name: "Claude Fast",
        user_id: 123,
        model: "anthropic/claude-3-haiku",
        request_type: "chat",
        input_tokens: 150,
        output_tokens: 320,
        total_tokens: 470,
        latency_ms: 850,
        status: "success",
        metadata: %{"temperature" => 0.7}
      })

      # Log a failed request
      {:ok, request} = PhoenixKit.AI.create_request(%{
        endpoint_id: 1,
        endpoint_name: "Claude Fast",
        model: "anthropic/claude-3-haiku",
        status: "error",
        error_message: "Rate limit exceeded"
      })
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.AI.Endpoint
  alias PhoenixKit.Users.Auth.User

  @primary_key {:id, :id, autogenerate: true}
  @valid_statuses ~w(success error timeout)
  @valid_request_types ~w(text_completion chat embedding)

  @derive {Jason.Encoder,
           only: [
             :id,
             :endpoint_id,
             :endpoint_name,
             :account_id,
             :user_id,
             :slot_index,
             :model,
             :request_type,
             :input_tokens,
             :output_tokens,
             :total_tokens,
             :cost_cents,
             :latency_ms,
             :status,
             :error_message,
             :metadata,
             :inserted_at
           ]}

  schema "phoenix_kit_ai_requests" do
    field :uuid, Ecto.UUID
    # New endpoint system fields
    field :endpoint_name, :string

    # Legacy fields (for backward compatibility)
    field :slot_index, :integer

    # Request details
    field :model, :string
    field :request_type, :string, default: "chat"
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :cost_cents, :integer
    field :latency_ms, :integer
    field :status, :string, default: "success"
    field :error_message, :string
    field :metadata, :map, default: %{}

    # Associations
    belongs_to :endpoint, Endpoint
    # Legacy account_id field (backward compatibility, no association since Account was removed)
    field :account_id, :integer
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for request creation.
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :endpoint_id,
      :endpoint_name,
      :account_id,
      :user_id,
      :slot_index,
      :model,
      :request_type,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cost_cents,
      :latency_ms,
      :status,
      :error_message,
      :metadata
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:request_type, @valid_request_types)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> calculate_total_tokens()
    |> foreign_key_constraint(:endpoint_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Returns the list of valid status types.
  """
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns the list of valid request types.
  """
  def valid_request_types, do: @valid_request_types

  @doc """
  Returns a human-readable status label.
  """
  def status_label("success"), do: "Success"
  def status_label("error"), do: "Error"
  def status_label("timeout"), do: "Timeout"
  def status_label(_), do: "Unknown"

  @doc """
  Returns a CSS class for the status badge.
  """
  def status_color("success"), do: "badge-success"
  def status_color("error"), do: "badge-error"
  def status_color("timeout"), do: "badge-warning"
  def status_color(_), do: "badge-neutral"

  @doc """
  Formats the latency for display.
  """
  def format_latency(nil), do: "-"
  def format_latency(ms) when ms < 1000, do: "#{ms}ms"
  def format_latency(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @doc """
  Formats the token count for display.
  """
  def format_tokens(nil), do: "-"
  def format_tokens(0), do: "0"
  def format_tokens(tokens) when tokens < 1000, do: "#{tokens}"
  def format_tokens(tokens) when tokens < 1_000_000, do: "#{Float.round(tokens / 1000, 1)}K"
  def format_tokens(tokens), do: "#{Float.round(tokens / 1_000_000, 2)}M"

  @doc """
  Formats the cost for display.

  Cost is stored in nanodollars (1/1000000 of a dollar) for precision.
  Shows appropriate precision based on the amount:
  - >= $1.00: 2 decimal places ($1.23)
  - >= $0.01: 2 decimal places ($0.05)
  - >= $0.0001: 4 decimal places ($0.0012)
  - > $0: 6 decimal places ($0.000030)
  """
  def format_cost(nil), do: "-"
  def format_cost(0), do: "$0.00"

  def format_cost(nanodollars) when is_integer(nanodollars) do
    # Convert from nanodollars (1/1000000 of a dollar) to dollars
    dollars = nanodollars / 1_000_000

    cond do
      dollars >= 0.01 -> "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
      dollars >= 0.0001 -> "$#{:erlang.float_to_binary(dollars, decimals: 4)}"
      dollars > 0 -> "$#{:erlang.float_to_binary(dollars, decimals: 6)}"
      true -> "$0.00"
    end
  end

  @doc """
  Extracts the model name without provider prefix.
  """
  def short_model_name(nil), do: "-"
  def short_model_name(""), do: "-"

  def short_model_name(model) do
    case String.split(model, "/") do
      [_provider, name | _rest] -> name
      [name] -> name
      _ -> model
    end
  end

  # Private functions

  defp calculate_total_tokens(changeset) do
    input = get_field(changeset, :input_tokens) || 0
    output = get_field(changeset, :output_tokens) || 0
    total = get_field(changeset, :total_tokens) || 0

    # Only calculate if total is 0 or not set
    if total == 0 and (input > 0 or output > 0) do
      put_change(changeset, :total_tokens, input + output)
    else
      changeset
    end
  end
end
