defmodule PhoenixKit.Modules.Shop.ImportConfig do
  @moduledoc """
  ImportConfig schema for configurable CSV import filtering.

  Allows defining custom filtering rules per import type instead of
  using hardcoded keywords.

  ## Fields

  - `name` - Config name (e.g., "decor_3d", "general")
  - `include_keywords` - Keywords that must be present for inclusion
  - `exclude_keywords` - Keywords that cause exclusion
  - `exclude_phrases` - Phrases that cause exclusion
  - `skip_filter` - If true, skip all filtering (import everything)
  - `category_rules` - List of maps: `[%{keywords: [...], slug: "category-slug"}]`
  - `default_category_slug` - Fallback category when no rules match
  - `required_columns` - CSV columns that must be present
  - `is_default` - Use this config when none specified
  - `active` - Config is available for use
  - `option_mappings` - Mappings from CSV option columns to global options

  ## Example Category Rules

      [
        %{"keywords" => ["shelf"], "slug" => "shelves"},
        %{"keywords" => ["mask"], "slug" => "masks"},
        %{"keywords" => ["vase", "planter"], "slug" => "vases-planters"}
      ]

  ## Example Option Mappings

      [
        %{
          "csv_name" => "Cup Color",
          "slot_key" => "cup_color",
          "source_key" => "color",
          "auto_add" => true,
          "label" => %{"en" => "Cup Color", "ru" => "Цвет чашки"}
        },
        %{
          "csv_name" => "Liquid Color",
          "slot_key" => "liquid_color",
          "source_key" => "color",
          "auto_add" => true
        }
      ]
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @default_required_columns ["Handle", "Title", "Variant Price"]

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_shop_import_configs" do
    field :name, :string

    # Filtering keywords (PostgreSQL TEXT[] arrays)
    field :include_keywords, {:array, :string}, default: []
    field :exclude_keywords, {:array, :string}, default: []
    field :exclude_phrases, {:array, :string}, default: []
    field :skip_filter, :boolean, default: false

    # Category assignment rules (JSONB)
    field :category_rules, {:array, :map}, default: []
    field :default_category_slug, :string

    # CSV validation
    field :required_columns, {:array, :string}, default: @default_required_columns

    # Status flags
    field :is_default, :boolean, default: false
    field :active, :boolean, default: true

    # Image migration options
    field :download_images, :boolean, default: false

    # Option mappings for CSV import (JSONB)
    field :option_mappings, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating an import config.
  """
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [
      :name,
      :include_keywords,
      :exclude_keywords,
      :exclude_phrases,
      :skip_filter,
      :category_rules,
      :default_category_slug,
      :required_columns,
      :is_default,
      :active,
      :download_images,
      :option_mappings
    ])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> unique_constraint(:uuid)
    |> validate_category_rules()
    |> validate_option_mappings()
  end

  defp validate_category_rules(changeset) do
    case get_field(changeset, :category_rules) do
      nil ->
        changeset

      rules when is_list(rules) ->
        if Enum.all?(rules, &valid_category_rule?/1) do
          changeset
        else
          add_error(
            changeset,
            :category_rules,
            "each rule must have 'keywords' (list) and 'slug' (string)"
          )
        end

      _ ->
        add_error(changeset, :category_rules, "must be a list of rule objects")
    end
  end

  defp valid_category_rule?(rule) when is_map(rule) do
    keywords = rule["keywords"] || rule[:keywords]
    slug = rule["slug"] || rule[:slug]

    is_list(keywords) and is_binary(slug) and slug != ""
  end

  defp valid_category_rule?(_), do: false

  defp validate_option_mappings(changeset) do
    case get_field(changeset, :option_mappings) do
      nil ->
        changeset

      mappings when is_list(mappings) ->
        if Enum.all?(mappings, &valid_option_mapping?/1) do
          changeset
        else
          add_error(
            changeset,
            :option_mappings,
            "each mapping must have 'csv_name' (string) and 'slot_key' (string)"
          )
        end

      _ ->
        add_error(changeset, :option_mappings, "must be a list of mapping objects")
    end
  end

  defp valid_option_mapping?(mapping) when is_map(mapping) do
    csv_name = mapping["csv_name"] || mapping[:csv_name]
    slot_key = mapping["slot_key"] || mapping[:slot_key]

    is_binary(csv_name) and csv_name != "" and
      is_binary(slot_key) and slot_key != ""
  end

  defp valid_option_mapping?(_), do: false

  @doc """
  Returns default required columns for CSV validation.
  """
  def default_required_columns, do: @default_required_columns

  @doc """
  Builds a config struct from legacy hardcoded values (for backward compatibility).
  """
  def from_legacy_defaults do
    %__MODULE__{
      name: "legacy_default",
      include_keywords:
        ~w(3d printed shelf mask vase planter holder stand lamp light figurine sculpture statue),
      exclude_keywords: ~w(decal sticker mural wallpaper poster tapestry canvas),
      exclude_phrases: ["wall art"],
      skip_filter: false,
      category_rules: [
        %{"keywords" => ["shelf"], "slug" => "shelves"},
        %{"keywords" => ["mask"], "slug" => "masks"},
        %{"keywords" => ["vase", "planter"], "slug" => "vases-planters"},
        %{"keywords" => ["holder", "stand"], "slug" => "holders-stands"},
        %{"keywords" => ["lamp", "light"], "slug" => "lamps"},
        %{"keywords" => ["figurine", "sculpture", "statue"], "slug" => "figurines"}
      ],
      default_category_slug: "other-3d",
      required_columns: @default_required_columns,
      is_default: true,
      active: true
    }
  end

  @doc """
  Builds a default config for Prom.ua imports (no filtering, import everything).
  """
  def from_prom_ua_defaults do
    %__MODULE__{
      name: "prom_ua_default",
      skip_filter: true,
      category_rules: [],
      required_columns: ["Назва_позиції", "Ціна"],
      is_default: false,
      active: true,
      download_images: true,
      include_keywords: [],
      exclude_keywords: [],
      exclude_phrases: []
    }
  end

  @doc """
  Builds a "no filter" config that imports everything.
  """
  def no_filter_config do
    %__MODULE__{
      name: "no_filter",
      skip_filter: true,
      category_rules: [],
      required_columns: @default_required_columns,
      is_default: false,
      active: true
    }
  end
end
