defmodule PhoenixKit.Modules.Legal do
  @moduledoc """
  Legal module for PhoenixKit - GDPR/CCPA compliant legal pages and consent management.

  ## Phase 1: Legal Pages Generation
  - Compliance framework selection (GDPR, CCPA, etc.)
  - Company information management
  - Legal page generation (Privacy Policy, Terms, Cookie Policy)
  - Integration with Publishing module for page storage

  ## Phase 2: Cookie Consent Widget (prepared infrastructure)
  - Cookie consent banner
  - Consent logging to phoenix_kit_consent_logs table
  - Google Consent Mode v2 integration

  ## Dependencies
  - Publishing module must be enabled before Legal module

  ## Usage

      # Enable the module (requires Publishing to be enabled)
      PhoenixKit.Modules.Legal.enable_system()

      # Check if enabled
      PhoenixKit.Modules.Legal.enabled?()

      # Get configuration
      PhoenixKit.Modules.Legal.get_config()

      # Generate legal pages
      PhoenixKit.Modules.Legal.generate_all_pages()
  """

  alias PhoenixKit.Modules.Legal.TemplateGenerator
  alias PhoenixKit.Settings

  @enabled_key "legal_enabled"
  @module_name "legal"
  @legal_blog_slug "legal"

  # Compliance frameworks with required and optional pages
  @frameworks %{
    "gdpr" => %{
      id: "gdpr",
      name: "GDPR (European Union)",
      description: "General Data Protection Regulation - strictest requirements, opt-in consent",
      regions: ["EU", "EEA"],
      consent_model: :opt_in,
      required_pages: ["privacy-policy", "cookie-policy"],
      optional_pages: ["terms-of-service", "data-retention-policy"]
    },
    "uk_gdpr" => %{
      id: "uk_gdpr",
      name: "UK GDPR (United Kingdom)",
      description: "Post-Brexit UK version, similar to EU GDPR",
      regions: ["UK"],
      consent_model: :opt_in,
      required_pages: ["privacy-policy", "cookie-policy"],
      optional_pages: ["terms-of-service"]
    },
    "ccpa" => %{
      id: "ccpa",
      name: "CCPA/CPRA (California)",
      description: "California Consumer Privacy Act - opt-out model, 'Do Not Sell' requirement",
      regions: ["US-CA"],
      consent_model: :opt_out,
      required_pages: ["privacy-policy", "do-not-sell"],
      optional_pages: ["terms-of-service", "ccpa-notice"]
    },
    "us_states" => %{
      id: "us_states",
      name: "US State Privacy Laws",
      description: "Virginia, Colorado, Connecticut, Utah + 15 more states",
      regions: ["US"],
      consent_model: :opt_out,
      required_pages: ["privacy-policy"],
      optional_pages: ["terms-of-service", "do-not-sell"]
    },
    "lgpd" => %{
      id: "lgpd",
      name: "LGPD (Brazil)",
      description: "Brazilian General Data Protection Law - opt-in consent",
      regions: ["BR"],
      consent_model: :opt_in,
      required_pages: ["privacy-policy"],
      optional_pages: ["terms-of-service", "cookie-policy"]
    },
    "pipeda" => %{
      id: "pipeda",
      name: "PIPEDA (Canada)",
      description: "Personal Information Protection and Electronic Documents Act",
      regions: ["CA"],
      consent_model: :opt_in,
      required_pages: ["privacy-policy"],
      optional_pages: ["terms-of-service", "cookie-policy"]
    },
    "generic" => %{
      id: "generic",
      name: "Generic (Basic)",
      description: "Basic privacy policy for other regions",
      regions: ["*"],
      consent_model: :notice,
      required_pages: ["privacy-policy"],
      optional_pages: ["terms-of-service", "cookie-policy"]
    }
  }

  # Standard pages that can be generated
  @page_types %{
    "privacy-policy" => %{
      slug: "privacy-policy",
      title: "Privacy Policy",
      template: "privacy_policy.eex",
      description: "Information about data collection, usage, and user rights"
    },
    "cookie-policy" => %{
      slug: "cookie-policy",
      title: "Cookie Policy",
      template: "cookie_policy.eex",
      description: "Details about cookies and tracking technologies"
    },
    "terms-of-service" => %{
      slug: "terms-of-service",
      title: "Terms of Service",
      template: "terms_of_service.eex",
      description: "Terms and conditions for using the service"
    },
    "do-not-sell" => %{
      slug: "do-not-sell",
      title: "Do Not Sell My Personal Information",
      template: "do_not_sell.eex",
      description: "CCPA opt-out page for California residents"
    },
    "data-retention-policy" => %{
      slug: "data-retention-policy",
      title: "Data Retention Policy",
      template: "data_retention_policy.eex",
      description: "GDPR data retention periods"
    },
    "ccpa-notice" => %{
      slug: "ccpa-notice",
      title: "CCPA Notice at Collection",
      template: "ccpa_notice.eex",
      description: "California notice at point of data collection"
    },
    "acceptable-use" => %{
      slug: "acceptable-use",
      title: "Acceptable Use Policy",
      template: "acceptable_use.eex",
      description: "Rules for acceptable use of the service"
    }
  }

  # ===================================
  # SYSTEM MANAGEMENT
  # ===================================

  @doc """
  Check if Legal module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enable the Legal module.

  Requires Publishing module to be enabled first.
  Creates the "legal" publishing group if it doesn't exist.

  ## Returns
  - `{:ok, :enabled}` - Successfully enabled
  - `{:error, :publishing_required}` - Publishing module must be enabled first
  """
  @spec enable_system() :: {:ok, :enabled} | {:error, :publishing_required | term()}
  def enable_system do
    # Check Publishing dependency
    if publishing_enabled?() do
      case Settings.update_boolean_setting_with_module(@enabled_key, true, @module_name) do
        {:ok, _} ->
          # Ensure legal blog exists
          ensure_legal_blog()
          {:ok, :enabled}

        error ->
          error
      end
    else
      {:error, :publishing_required}
    end
  end

  @doc """
  Disable the Legal module.
  """
  @spec disable_system() :: {:ok, term()} | {:error, term()}
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  # ===================================
  # CONFIGURATION
  # ===================================

  @doc """
  Get the full configuration of the Legal module.

  Returns a map with:
  - enabled: boolean
  - frameworks: list of selected framework IDs
  - company_info: map with company details
  - dpo_contact: map with DPO contact info
  - generated_pages: list of generated page slugs
  - consent_widget_enabled: boolean (Phase 2)
  """
  @spec get_config() :: map()
  def get_config do
    %{
      enabled: enabled?(),
      publishing_enabled: publishing_enabled?(),
      frameworks: get_selected_frameworks(),
      company_info: get_company_info(),
      dpo_contact: get_dpo_contact(),
      generated_pages: list_generated_pages(),
      consent_widget_enabled: consent_widget_enabled?(),
      cookie_banner_position: get_cookie_banner_position()
    }
  end

  @doc """
  Get available compliance frameworks.
  """
  @spec available_frameworks() :: map()
  def available_frameworks, do: @frameworks

  @doc """
  Get available page types.
  """
  @spec available_page_types() :: map()
  def available_page_types, do: @page_types

  @doc """
  Get selected compliance frameworks.
  """
  @spec get_selected_frameworks() :: list(String.t())
  def get_selected_frameworks do
    case Settings.get_json_setting("legal_frameworks", %{"items" => []}) do
      %{"items" => items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Set compliance frameworks.

  ## Parameters
  - framework_ids: List of framework IDs to enable

  ## Returns
  - `{:ok, setting}` on success
  - `{:error, reason}` on failure
  """
  @spec set_frameworks(list(String.t())) :: {:ok, term()} | {:error, term()}
  def set_frameworks(framework_ids) when is_list(framework_ids) do
    valid_ids = Enum.filter(framework_ids, &Map.has_key?(@frameworks, &1))

    Settings.update_json_setting_with_module(
      "legal_frameworks",
      %{"items" => valid_ids},
      @module_name
    )
  end

  @default_company_info %{
    "name" => "",
    "address_line1" => "",
    "address_line2" => "",
    "city" => "",
    "state" => "",
    "postal_code" => "",
    "country" => "",
    "registration_number" => "",
    "vat_number" => ""
  }

  @doc """
  Get company information.

  Reads from consolidated `company_info` key with fallback to legacy `legal_company_info`.
  """
  @spec get_company_info() :: map()
  def get_company_info do
    case Settings.get_json_setting("company_info", nil) do
      nil ->
        # Fallback to legacy legal_company_info key
        Settings.get_json_setting("legal_company_info", @default_company_info)

      info when is_map(info) ->
        Map.merge(@default_company_info, info)

      _ ->
        @default_company_info
    end
  end

  @doc """
  Update company information.
  """
  @spec update_company_info(map()) :: {:ok, term()} | {:error, term()}
  def update_company_info(params) when is_map(params) do
    current = get_company_info()
    merged = Map.merge(current, stringify_keys(params))
    Settings.update_json_setting_with_module("legal_company_info", merged, @module_name)
  end

  @doc """
  Get Data Protection Officer contact.
  """
  @spec get_dpo_contact() :: map()
  def get_dpo_contact do
    default = %{
      "name" => "",
      "email" => "",
      "phone" => "",
      "address" => ""
    }

    Settings.get_json_setting("legal_dpo_contact", default)
  end

  @doc """
  Update DPO contact information.
  """
  @spec update_dpo_contact(map()) :: {:ok, term()} | {:error, term()}
  def update_dpo_contact(params) when is_map(params) do
    current = get_dpo_contact()
    merged = Map.merge(current, stringify_keys(params))
    Settings.update_json_setting_with_module("legal_dpo_contact", merged, @module_name)
  end

  # ===================================
  # CONSENT WIDGET (Phase 2)
  # ===================================

  @opt_in_frameworks ~w(gdpr uk_gdpr lgpd pipeda)

  @doc """
  Check if consent widget is enabled (Phase 2 feature).
  """
  @spec consent_widget_enabled?() :: boolean()
  def consent_widget_enabled? do
    Settings.get_boolean_setting("legal_consent_widget_enabled", false)
  end

  @doc """
  Enable consent widget.
  """
  @spec enable_consent_widget() :: {:ok, term()} | {:error, term()}
  def enable_consent_widget do
    Settings.update_boolean_setting_with_module(
      "legal_consent_widget_enabled",
      true,
      @module_name
    )
  end

  @doc """
  Disable consent widget.
  """
  @spec disable_consent_widget() :: {:ok, term()} | {:error, term()}
  def disable_consent_widget do
    Settings.update_boolean_setting_with_module(
      "legal_consent_widget_enabled",
      false,
      @module_name
    )
  end

  @doc """
  Check if consent icon should be shown.

  Returns true only if:
  - Legal module is enabled
  - Consent widget is enabled
  - Consent mode is "strict"
  - At least one opt-in framework is selected (GDPR, UK GDPR, LGPD, PIPEDA)
  """
  @spec should_show_consent_icon?() :: boolean()
  def should_show_consent_icon? do
    enabled?() and
      consent_widget_enabled?() and
      get_consent_mode() == "strict" and
      has_opt_in_framework?()
  end

  @doc """
  Check if any opt-in framework is selected.
  """
  @spec has_opt_in_framework?() :: boolean()
  def has_opt_in_framework? do
    get_selected_frameworks()
    |> Enum.any?(&(&1 in @opt_in_frameworks))
  end

  @doc """
  Get cookie banner/icon position.
  Options: "bottom-left", "bottom-right", "top-left", "top-right"
  """
  @spec get_cookie_banner_position() :: String.t()
  def get_cookie_banner_position do
    Settings.get_setting("legal_cookie_banner_position", "bottom-right")
  end

  @doc """
  Alias for get_cookie_banner_position/0.
  """
  @spec get_icon_position() :: String.t()
  def get_icon_position, do: get_cookie_banner_position()

  @doc """
  Update cookie banner/icon position.
  """
  @spec update_icon_position(String.t()) :: {:ok, term()} | {:error, term()}
  def update_icon_position(position)
      when position in ~w(bottom-left bottom-right top-left top-right) do
    Settings.update_setting_with_module("legal_cookie_banner_position", position, @module_name)
  end

  def update_icon_position(_), do: {:error, :invalid_position}

  @doc """
  Get policy version for consent tracking.
  Changing this version will prompt users to re-consent.
  """
  @spec get_policy_version() :: String.t()
  def get_policy_version do
    Settings.get_setting("legal_policy_version", "1.0")
  end

  @doc """
  Update policy version.
  """
  @spec update_policy_version(String.t()) :: {:ok, term()} | {:error, term()}
  def update_policy_version(version) when is_binary(version) do
    Settings.update_setting_with_module("legal_policy_version", version, @module_name)
  end

  @doc """
  Check if Google Consent Mode v2 is enabled.
  """
  @spec google_consent_mode_enabled?() :: boolean()
  def google_consent_mode_enabled? do
    Settings.get_boolean_setting("legal_google_consent_mode", false)
  end

  @doc """
  Enable Google Consent Mode v2.
  """
  @spec enable_google_consent_mode() :: {:ok, term()} | {:error, term()}
  def enable_google_consent_mode do
    Settings.update_boolean_setting_with_module("legal_google_consent_mode", true, @module_name)
  end

  @doc """
  Disable Google Consent Mode v2.
  """
  @spec disable_google_consent_mode() :: {:ok, term()} | {:error, term()}
  def disable_google_consent_mode do
    Settings.update_boolean_setting_with_module("legal_google_consent_mode", false, @module_name)
  end

  # ===================================
  # CONSENT MODE SETTINGS
  # ===================================

  @consent_modes ~w(strict notice)

  @doc """
  Get consent mode.

  Modes:
  - "strict" - Full compliance: icon, script blocking, re-consent on policy change
  - "notice" - Simple notice: banner once, no blocking, no icon

  Default: "strict" for opt-in frameworks, "notice" otherwise.
  """
  @spec get_consent_mode() :: String.t()
  def get_consent_mode do
    stored = Settings.get_setting("legal_consent_mode", nil)

    case stored do
      mode when mode in @consent_modes -> mode
      _ -> if has_opt_in_framework?(), do: "strict", else: "notice"
    end
  end

  @doc """
  Update consent mode.
  """
  @spec update_consent_mode(String.t()) :: {:ok, term()} | {:error, term()}
  def update_consent_mode(mode) when mode in @consent_modes do
    Settings.update_setting_with_module("legal_consent_mode", mode, @module_name)
  end

  def update_consent_mode(_), do: {:error, :invalid_mode}

  @doc """
  Check if consent widget should be hidden for authenticated users.
  Only applies in "notice" mode.
  """
  @spec hide_for_authenticated?() :: boolean()
  def hide_for_authenticated? do
    Settings.get_boolean_setting("legal_hide_for_authenticated", false)
  end

  @doc """
  Update hide for authenticated setting.
  """
  @spec update_hide_for_authenticated(boolean()) :: {:ok, term()} | {:error, term()}
  def update_hide_for_authenticated(value) when is_boolean(value) do
    Settings.update_boolean_setting_with_module(
      "legal_hide_for_authenticated",
      value,
      @module_name
    )
  end

  @doc """
  Get full consent widget configuration for the component.

  Returns a map with all settings needed by the cookie_consent component:
  - enabled: boolean
  - consent_mode: "strict" | "notice"
  - show_icon: boolean
  - icon_position: string
  - policy_version: string
  - google_consent_mode: boolean
  - hide_for_authenticated: boolean
  - frameworks: list of framework IDs
  - cookie_policy_url: string
  - privacy_policy_url: string
  """
  @spec get_consent_widget_config() :: map()
  def get_consent_widget_config do
    prefix = PhoenixKit.Config.get_url_prefix()

    %{
      enabled: consent_widget_enabled?(),
      consent_mode: get_consent_mode(),
      show_icon: should_show_consent_icon?(),
      hide_for_authenticated: hide_for_authenticated?(),
      icon_position: get_icon_position(),
      policy_version: get_auto_policy_version(),
      google_consent_mode: google_consent_mode_enabled?(),
      frameworks: get_selected_frameworks(),
      cookie_policy_url: "#{prefix}/legal/cookie-policy",
      privacy_policy_url: "#{prefix}/legal/privacy-policy"
    }
  end

  @doc """
  Check if there are unpublished legal pages that are required.

  Returns a list of unpublished page slugs (e.g., ["cookie-policy", "privacy-policy"]).
  """
  @spec get_unpublished_required_pages() :: list(String.t())
  def get_unpublished_required_pages do
    required_pages = ["cookie-policy", "privacy-policy"]
    generated = list_generated_pages()

    Enum.filter(required_pages, fn slug ->
      case Enum.find(generated, &(&1.slug == slug)) do
        nil -> true
        %{status: "published"} -> false
        _ -> true
      end
    end)
  end

  @doc """
  Check if all required legal pages are published.
  """
  @spec all_required_pages_published?() :: boolean()
  def all_required_pages_published? do
    get_unpublished_required_pages() == []
  end

  @doc """
  Get auto-calculated policy version based on legal page updates.

  Uses the latest updated_at from cookie-policy or privacy-policy pages.
  Falls back to manual version if no pages exist.
  """
  @spec get_auto_policy_version() :: String.t()
  def get_auto_policy_version do
    pages = list_generated_pages()

    latest =
      pages
      |> Enum.filter(&(&1.slug in ["cookie-policy", "privacy-policy"]))
      |> Enum.map(& &1.updated_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    case latest do
      nil -> get_policy_version()
      datetime -> format_version_date(datetime)
    end
  end

  defp format_version_date(datetime) when is_binary(datetime) do
    # Already a string, try to parse and format
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> datetime
    end
  end

  defp format_version_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d")
  end

  defp format_version_date(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d")
  end

  defp format_version_date(_), do: get_policy_version()

  # ===================================
  # PAGE GENERATION
  # ===================================

  @doc """
  Generate a legal page from template.

  ## Parameters
  - page_type: Page type slug (e.g., "privacy-policy")
  - opts: Keyword options
    - :language - Language code (default: "en")
    - :scope - User scope for audit trail

  ## Returns
  - `{:ok, post}` on success
  - `{:error, reason}` on failure
  """
  @spec generate_page(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_page(page_type, opts \\ []) do
    language = Keyword.get(opts, :language, "en")
    scope = Keyword.get(opts, :scope, nil)

    with {:ok, page_config} <- get_page_config(page_type),
         {:ok, content} <- render_template(page_config.template) do
      create_or_update_legal_post(page_config, content, language, scope)
    end
  end

  @doc """
  Publish a legal page by slug.

  ## Parameters
  - page_slug: The slug of the page to publish (e.g., "cookie-policy")
  - opts: Keyword options
    - :scope - User scope for audit trail

  ## Returns
  - `{:ok, post}` on success
  - `{:error, reason}` on failure
  """
  @spec publish_page(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_page(page_slug, opts \\ []) do
    scope = Keyword.get(opts, :scope, nil)

    case publishing_module().read_post(@legal_blog_slug, page_slug) do
      {:ok, post} ->
        publishing_module().update_post(
          @legal_blog_slug,
          post,
          %{"status" => "published"},
          scope: scope
        )

      {:error, :not_found} ->
        {:error, :page_not_found}

      error ->
        error
    end
  end

  @doc """
  Generate all required pages for selected frameworks.

  ## Parameters
  - opts: Keyword options
    - :language - Language code (default: "en")
    - :scope - User scope for audit trail
    - :include_optional - Include optional pages (default: false)

  ## Returns
  - `{:ok, results}` - Map of page_type => result
  """
  @spec generate_all_pages(keyword()) :: {:ok, map()}
  def generate_all_pages(opts \\ []) do
    include_optional = Keyword.get(opts, :include_optional, false)
    frameworks = get_selected_frameworks()

    pages =
      if include_optional do
        get_all_pages_for_frameworks(frameworks)
      else
        get_required_pages_for_frameworks(frameworks)
      end

    results =
      pages
      |> Enum.map(fn page_type ->
        {page_type, generate_page(page_type, opts)}
      end)
      |> Map.new()

    {:ok, results}
  end

  @doc """
  List generated legal pages.
  """
  @spec list_generated_pages() :: list(map())
  def list_generated_pages do
    if publishing_enabled?() do
      posts = publishing_module().list_posts(@legal_blog_slug)

      Enum.map(posts, fn post ->
        %{
          slug: post.slug,
          path: post.path,
          title: get_in(post, [:metadata, :title]) || post.slug,
          status: get_in(post, [:metadata, :status]) || "draft",
          updated_at: get_in(post, [:metadata, :updated_at])
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Get pages required for given frameworks.
  """
  @spec get_required_pages_for_frameworks(list(String.t())) :: list(String.t())
  def get_required_pages_for_frameworks(framework_ids) do
    framework_ids
    |> Enum.flat_map(fn id ->
      case Map.get(@frameworks, id) do
        nil -> []
        framework -> framework.required_pages
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Get all pages (required + optional) for given frameworks.
  """
  @spec get_all_pages_for_frameworks(list(String.t())) :: list(String.t())
  def get_all_pages_for_frameworks(framework_ids) do
    framework_ids
    |> Enum.flat_map(fn id ->
      case Map.get(@frameworks, id) do
        nil -> []
        framework -> framework.required_pages ++ framework.optional_pages
      end
    end)
    |> Enum.uniq()
  end

  # ===================================
  # PRIVATE HELPERS
  # ===================================

  defp publishing_enabled? do
    publishing_module().enabled?()
  rescue
    _ -> false
  end

  defp publishing_module do
    PhoenixKit.Modules.Publishing
  end

  defp ensure_legal_blog do
    # First check if legal blog already exists
    case publishing_module().get_group(@legal_blog_slug) do
      {:ok, _existing_blog} ->
        {:ok, :exists}

      {:error, :not_found} ->
        # Blog doesn't exist, create it
        case publishing_module().add_group("Legal",
               mode: "slug",
               slug: @legal_blog_slug,
               type: "legal"
             ) do
          {:ok, _blog} -> {:ok, :created}
          {:error, :already_exists} -> {:ok, :exists}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e -> {:error, e}
  end

  defp get_page_config(page_type) do
    case Map.get(@page_types, page_type) do
      nil -> {:error, :unknown_page_type}
      config -> {:ok, config}
    end
  end

  defp render_template(template_name) do
    context = build_template_context()
    TemplateGenerator.render(template_name, context)
  end

  defp build_template_context do
    company = get_company_info()
    dpo = get_dpo_contact()
    frameworks = get_selected_frameworks()

    # Format full address from individual fields
    company_address = format_company_address(company)

    # Use site_url from General Settings (consolidated location)
    website_url = Settings.get_setting("site_url", "")

    %{
      company_name: company["name"] || "",
      company_address: company_address,
      company_country: get_country_name(company["country"]),
      company_website: website_url,
      registration_number: company["registration_number"] || "",
      vat_number: company["vat_number"] || "",
      dpo_name: dpo["name"] || "",
      dpo_email: dpo["email"] || "",
      dpo_phone: dpo["phone"] || "",
      dpo_address: dpo["address"] || "",
      frameworks: frameworks,
      effective_date: Date.utc_today() |> Date.to_string()
    }
  end

  defp format_company_address(company) do
    [
      company["address_line1"],
      company["address_line2"],
      [company["city"], company["state"]]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.join(", "),
      company["postal_code"],
      get_country_name(company["country"])
    ]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n")
  end

  defp get_country_name(nil), do: ""
  defp get_country_name(""), do: ""

  defp get_country_name(country_code) do
    case BeamLabCountries.get(country_code) do
      nil -> country_code
      country -> country.name
    end
  end

  defp create_or_update_legal_post(page_config, content, _language, scope) do
    # Build the full markdown content with title
    full_content = "# #{page_config.title}\n\n#{content}"

    # Check if post already exists
    case publishing_module().read_post(@legal_blog_slug, page_config.slug) do
      {:ok, existing_post} ->
        # Update existing post (keep current status)
        publishing_module().update_post(
          @legal_blog_slug,
          existing_post,
          %{
            "content" => full_content
          },
          scope: scope
        )

      {:error, :not_found} ->
        # Create new post as draft (user must publish manually)
        publishing_module().create_post(@legal_blog_slug, %{
          title: page_config.title,
          slug: page_config.slug,
          scope: scope
        })
        |> case do
          {:ok, post} ->
            # Update with content (stays as draft)
            publishing_module().update_post(
              @legal_blog_slug,
              post,
              %{"content" => full_content, "status" => "draft"},
              scope: scope
            )

          error ->
            error
        end

      error ->
        error
    end
  rescue
    e -> {:error, e}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
