defmodule PhoenixKit.Modules.Billing.Providers.Types.ProviderInfo do
  @moduledoc """
  Struct for payment provider display information.

  ## Fields

  - `name` - Human-readable provider name (e.g., `"Stripe"`)
  - `icon` - Icon identifier for rendering
  - `color` - Brand color hex code
  - `description` - Short description of the provider
  """

  @enforce_keys [:name, :icon, :color]
  defstruct [:name, :icon, :color, :description]

  @type t :: %__MODULE__{
          name: String.t(),
          icon: String.t(),
          color: String.t(),
          description: String.t() | nil
        }
end
