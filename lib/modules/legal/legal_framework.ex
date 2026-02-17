defmodule PhoenixKit.Modules.Legal.LegalFramework do
  @moduledoc """
  Struct representing a legal compliance framework.

  ## Fields

  - `id` - Framework identifier (e.g., "gdpr", "ccpa")
  - `name` - Human-readable name (e.g., "GDPR (European Union)")
  - `description` - Brief description of the framework
  - `regions` - List of region codes where the framework applies
  - `consent_model` - Consent approach (`:opt_in`, `:opt_out`, or `:notice`)
  - `required_pages` - List of page slugs required by this framework
  - `optional_pages` - List of optional page slugs
  """

  @enforce_keys [:id, :name, :consent_model, :required_pages]
  defstruct [
    :id,
    :name,
    :description,
    regions: [],
    consent_model: :notice,
    required_pages: [],
    optional_pages: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          regions: [String.t()],
          consent_model: :opt_in | :opt_out | :notice,
          required_pages: [String.t()],
          optional_pages: [String.t()]
        }

  @doc """
  Converts a plain map to a `%LegalFramework{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map[:id] || map["id"],
      name: map[:name] || map["name"],
      description: map[:description] || map["description"],
      regions: map[:regions] || map["regions"] || [],
      consent_model: map[:consent_model] || map["consent_model"] || :notice,
      required_pages: map[:required_pages] || map["required_pages"] || [],
      optional_pages: map[:optional_pages] || map["optional_pages"] || []
    }
  end
end
