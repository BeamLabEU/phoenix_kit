defmodule PhoenixKit.Modules.Billing.Providers.Types.CheckoutSession do
  @moduledoc """
  Struct returned by `Provider.create_checkout_session/2`.

  ## Fields

  - `id` - Provider-specific session identifier
  - `url` - Redirect URL for the hosted checkout page
  - `provider` - Provider atom (`:stripe`, `:paypal`, `:razorpay`)
  - `expires_at` - When the session expires (nil if no expiry)
  - `metadata` - Provider-specific metadata
  """

  @enforce_keys [:id, :url, :provider]
  defstruct [:id, :url, :provider, :expires_at, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          provider: atom(),
          expires_at: DateTime.t() | nil,
          metadata: map()
        }
end
