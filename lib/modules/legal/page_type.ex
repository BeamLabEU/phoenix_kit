defmodule PhoenixKit.Modules.Legal.PageType do
  @moduledoc """
  Struct representing a type of legal page that can be generated.

  ## Fields

  - `slug` - URL-safe identifier (e.g., "privacy-policy")
  - `title` - Human-readable page title (e.g., "Privacy Policy")
  - `template` - EEx template filename for generation
  - `description` - Brief description of the page's purpose
  """

  @enforce_keys [:slug, :title, :template]
  defstruct [:slug, :title, :template, :description]

  @type t :: %__MODULE__{
          slug: String.t(),
          title: String.t(),
          template: String.t(),
          description: String.t() | nil
        }

  @doc """
  Converts a plain map to a `%PageType{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      slug: map[:slug] || map["slug"],
      title: map[:title] || map["title"],
      template: map[:template] || map["template"],
      description: map[:description] || map["description"]
    }
  end
end
