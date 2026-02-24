defmodule PhoenixKit.Modules.Shop.Web.Helpers do
  @moduledoc """
  Shared helper functions for Shop public LiveViews.

  Centralizes utility functions that were duplicated across shop_catalog,
  catalog_category, catalog_product, cart_page, checkout_page, and checkout_complete.
  """

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  # ---------------------------------------------------------------------------
  # Price formatting
  # ---------------------------------------------------------------------------

  @doc "Format a price value with currency. Returns \"-\" for nil price."
  def format_price(nil, _currency), do: "-"

  def format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  def format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  # ---------------------------------------------------------------------------
  # Current user
  # ---------------------------------------------------------------------------

  @doc "Extract current user from socket assigns scope."
  def get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{id: _} = user} -> user
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Language helpers
  # ---------------------------------------------------------------------------

  @doc """
  Determine language from URL params.

  Uses locale param if present, otherwise falls back to Translations.default_language/0.
  Used by catalog and category pages (non-product pages).
  """
  def get_language_from_params_or_default(%{"locale" => locale}) when is_binary(locale) do
    DialectMapper.resolve_dialect(locale, nil)
  end

  def get_language_from_params_or_default(_params) do
    Translations.default_language()
  end

  @doc """
  Find the best enabled language that has a slug for this entity.

  Prefers the default language, then checks other enabled languages.
  Returns nil if no valid language found.
  """
  def best_redirect_language(slug_map) when slug_map == %{}, do: nil

  def best_redirect_language(slug_map) do
    enabled = Languages.get_enabled_languages()
    default_first = Enum.sort_by(enabled, fn l -> if l.is_default, do: 0, else: 1 end)

    Enum.find_value(default_first, fn lang ->
      code = lang.code
      base = DialectMapper.extract_base(code)
      if Map.has_key?(slug_map, code) or Map.has_key?(slug_map, base), do: code
    end)
  end

  @doc """
  Build a localized URL path, adding language prefix for non-default languages.
  Delegates to Routes.path which handles default vs non-default consistently.
  """
  def build_lang_url(path, lang) do
    base = DialectMapper.extract_base(lang)
    Routes.path(path, locale: base)
  end

  # ---------------------------------------------------------------------------
  # Pagination helpers
  # ---------------------------------------------------------------------------

  @doc "Parse page param with validation. Returns 1 for invalid/missing values."
  def parse_page(nil), do: 1
  def parse_page(""), do: 1

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
  end

  def parse_page(page) when is_integer(page) and page > 0, do: page
  def parse_page(_), do: 1

  # ---------------------------------------------------------------------------
  # Image helpers (for catalog list pages - uses featured_image_id)
  # ---------------------------------------------------------------------------

  @doc """
  Get the first image URL for a product.

  Handles Storage-based images (new format with featured_image_id or image_ids)
  and legacy URL-based images (Shopify imports).
  Returns nil if no image is available.
  """
  def first_image(%{featured_image_id: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  def first_image(%{image_ids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  # Legacy URL-based images (Shopify imports)
  def first_image(%{images: [%{"src" => src} | _]}), do: src
  def first_image(%{images: [first | _]}) when is_binary(first), do: first
  def first_image(_), do: nil

  @doc """
  Get signed URL for a Storage image file.

  Returns nil if file or variant not found (unlike product detail page
  which returns a placeholder). Falls back to original variant if
  requested variant is not available.
  """
  def get_storage_image_url(file_id, variant) do
    case Storage.get_file(file_id) do
      %{uuid: uuid} ->
        case Storage.get_file_instance_by_name(uuid, variant) do
          nil ->
            case Storage.get_file_instance_by_name(uuid, "original") do
              nil -> nil
              _instance -> URLSigner.signed_url(file_id, "original")
            end

          _instance ->
            URLSigner.signed_url(file_id, variant)
        end

      nil ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # UI helpers
  # ---------------------------------------------------------------------------

  @doc """
  Convert a key string to human-readable format.

  Example: "material_type" -> "Material Type"
  """
  def humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize_key(key), do: to_string(key)

  # ---------------------------------------------------------------------------
  # Billing profile helpers
  # ---------------------------------------------------------------------------

  @doc "Format display name for a billing profile."
  def profile_display_name(%{type: "company"} = profile) do
    profile.company_name || "#{profile.first_name} #{profile.last_name}"
  end

  def profile_display_name(profile) do
    "#{profile.first_name} #{profile.last_name}"
  end

  @doc "Format address for a billing profile."
  def profile_address(profile) do
    [profile.address_line1, profile.city, profile.postal_code, profile.country]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end
end
