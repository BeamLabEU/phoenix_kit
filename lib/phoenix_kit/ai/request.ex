defmodule PhoenixKit.AI.Request do
  @moduledoc """
  AI request schema for PhoenixKit AI system.

  Tracks every AI API request for usage history and statistics.
  Used for monitoring costs, performance, and debugging.

  ## Schema Fields

  ### Request Identity
  - `account_id`: Foreign key to the AI account used (nullable if account deleted)
  - `user_id`: Foreign key to the user who made the request (nullable if user deleted)
  - `slot_index`: Which text processing slot was used (0, 1, or 2)

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

      # Log a successful request
      {:ok, request} = PhoenixKit.AI.create_request(%{
        account_id: 1,
        user_id: 123,
        slot_index: 0,
        model: "anthropic/claude-3-haiku",
        request_type: "text_completion",
        input_tokens: 150,
        output_tokens: 320,
        total_tokens: 470,
        latency_ms: 850,
        status: "success",
        metadata: %{"temperature" => 0.7}
      })

      # Log a failed request
      {:ok, request} = PhoenixKit.AI.create_request(%{
        account_id: 1,
        user_id: 123,
        model: "anthropic/claude-3-opus",
        status: "error",
        error_message: "Rate limit exceeded"
      })
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.AI.Account
  alias PhoenixKit.Users.Auth.User

  @primary_key {:id, :id, autogenerate: true}
  @valid_statuses ~w(success error timeout)
  @valid_request_types ~w(text_completion chat embedding)

  @derive {Jason.Encoder,
           only: [
             :id,
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
    field :slot_index, :integer
    field :model, :string
    field :request_type, :string, default: "text_completion"
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :cost_cents, :integer
    field :latency_ms, :integer
    field :status, :string, default: "success"
    field :error_message, :string
    field :metadata, :map, default: %{}

    belongs_to :account, Account
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for request creation.
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
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
    |> validate_number(:slot_index, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> calculate_total_tokens()
    |> foreign_key_constraint(:account_id)
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
  """
  def format_cost(nil), do: "-"
  def format_cost(0), do: "$0.00"
  def format_cost(cents), do: "$#{Float.round(cents / 100, 2)}"

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
