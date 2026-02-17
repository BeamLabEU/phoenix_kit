defmodule PhoenixKit.Modules.Billing.Providers.Types.WebhookEventData do
  @moduledoc """
  Struct returned by `Provider.handle_webhook_event/1`.

  Named `WebhookEventData` to avoid clash with the `WebhookEvent` Ecto schema.

  ## Fields

  - `type` - Normalized event type (e.g., `"checkout.completed"`, `"payment.succeeded"`)
  - `event_id` - Provider-specific event identifier
  - `data` - Normalized event payload
  - `provider` - Provider atom (`:stripe`, `:paypal`, `:razorpay`)
  - `raw_payload` - Original provider payload
  """

  @enforce_keys [:type, :event_id, :provider]
  defstruct [:type, :event_id, :provider, data: %{}, raw_payload: %{}]

  @type t :: %__MODULE__{
          type: String.t(),
          event_id: String.t(),
          data: map(),
          provider: atom(),
          raw_payload: map()
        }
end
