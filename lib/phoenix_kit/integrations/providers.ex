defmodule PhoenixKit.Integrations.Providers do
  @moduledoc """
  Registry of known integration providers.

  Each provider definition describes how to connect to an external service:
  what auth type it uses, what fields the admin needs to fill in, and
  how to validate the connection.

  Providers are defined in code, not in the database. New providers are
  added here as needed. External modules can also contribute providers
  via the `integration_providers/0` callback on `PhoenixKit.Module`.
  """

  require Logger

  alias PhoenixKit.ModuleRegistry

  @type auth_type :: :oauth2 | :api_key | :key_secret | :bot_token | :credentials

  @type setup_field :: %{
          key: String.t(),
          label: String.t(),
          type: :text | :password | :textarea | :number | :select,
          required: boolean(),
          placeholder: String.t(),
          help: String.t() | nil,
          options: [%{value: String.t(), label: String.t()}] | nil
        }

  @type provider :: %{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          icon: String.t(),
          auth_type: auth_type(),
          oauth_config: map() | nil,
          setup_fields: [setup_field()],
          capabilities: [atom()]
        }

  @doc """
  Returns all known providers, including those contributed by external modules.
  """
  @spec all() :: [provider()]
  def all do
    builtin_providers() ++ external_providers()
  end

  @doc """
  Look up a single provider by key.

  Accepts both plain keys (`"google"`) and named keys (`"google:personal"`) —
  the name is stripped before lookup since provider definitions are per-type.
  """
  @spec get(String.t()) :: provider() | nil
  def get(key) when is_binary(key) do
    # Strip name if present (e.g., "google:personal" -> "google")
    base_key =
      case String.split(key, ":", parts: 2) do
        [base, _name] -> base
        [base] -> base
      end

    Enum.find(all(), fn p -> p.key == base_key end)
  end

  # ---------------------------------------------------------------------------
  # Built-in provider definitions
  # ---------------------------------------------------------------------------

  defp builtin_providers do
    [
      google(),
      openrouter()
    ]
  end

  defp google do
    %{
      key: "google",
      name: "Google",
      description: "Google Docs, Drive, Calendar, Sheets, Gmail",
      icon: "hero-cloud",
      auth_type: :oauth2,
      oauth_config: %{
        auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
        token_url: "https://oauth2.googleapis.com/token",
        userinfo_url: "https://www.googleapis.com/oauth2/v2/userinfo",
        default_scopes:
          "openid email profile https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents",
        auth_params: %{"access_type" => "offline", "prompt" => "consent"}
      },
      setup_fields: [
        %{
          key: "client_id",
          label: "Client ID",
          type: :text,
          required: true,
          placeholder: "xxxxx.apps.googleusercontent.com",
          help: "From Google Cloud Console → APIs & Services → Credentials",
          options: nil
        },
        %{
          key: "client_secret",
          label: "Client Secret",
          type: :password,
          required: true,
          placeholder: "GOCSPX-...",
          help: nil,
          options: nil
        }
      ],
      capabilities: [:google_docs, :google_drive, :google_calendar, :google_sheets],
      instructions: [
        %{
          title: "Create a Google Cloud project",
          steps: [
            {"Go to the [Google Cloud Console](https://console.cloud.google.com)", nil},
            {"Create a new project or select an existing one", nil}
          ]
        },
        %{
          title: "Enable required APIs",
          steps: [
            {"Go to [APIs & Services → Library](https://console.cloud.google.com/apis/library)",
             nil},
            {"Search for **Google Drive API**, click it, then click **Enable**", nil},
            {"Go back to the Library and search for **Google Docs API**, click it, then click **Enable**",
             nil}
          ],
          note:
            "Drive API handles file listing, creation, copying, and PDF export. Docs API is used for reading document content and substituting template variables."
        },
        %{
          title: "Set up OAuth consent",
          steps: [
            {"Go to [Branding](https://console.cloud.google.com/auth/branding) in the sidebar — fill in the **App name** and **User support email**, then save",
             nil},
            {"Go to [Audience](https://console.cloud.google.com/auth/audience) — set user type to **External** (or Internal for Google Workspace)",
             nil},
            {"Still on Audience — while the app is in **Testing** status, add the Google account you will connect as a **Test user** (this must be the same account whose Drive will store your files)",
             nil},
            {"Go to [Data Access](https://console.cloud.google.com/auth/scopes) — click **Add or Remove Scopes** and add the Drive and Docs scopes. This step may not be required — the app requests the needed scopes at connect time regardless.",
             nil}
          ],
          note:
            "Navigate to the OAuth section using the search bar or the hamburger menu: search for \"OAuth\", or go to the sidebar: **APIs & Services → OAuth consent screen**. This opens a different section with its own sidebar."
        },
        %{
          title: "Create an OAuth Client",
          steps: [
            {"Go to [APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials)",
             nil},
            {"Click **Create Credentials → OAuth client ID**", nil},
            {"Application type: **Web application** (do not select \"Desktop app\" — it won't support redirect URIs)",
             nil},
            {"Under **Authorized redirect URIs**, add: `{redirect_uri}`", nil},
            {"Copy the **Client ID** and **Client Secret** into the form above", nil}
          ]
        },
        %{
          title: "Connect and authorize",
          steps: [
            {"Click **Save**, then **Connect Account**", nil},
            {"Google will show an \"unverified app\" warning — click **Advanced → Go to (app name)** to proceed",
             nil},
            {"Grant access to Google Docs and Google Drive", nil},
            {"You'll be redirected back here once connected", nil}
          ]
        }
      ]
    }
  end

  defp openrouter do
    %{
      key: "openrouter",
      name: "OpenRouter",
      description: "AI model access via OpenRouter (100+ models)",
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      validation: %{
        url: "https://openrouter.ai/api/v1/auth/key",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: "API Key",
          type: :password,
          required: true,
          placeholder: "sk-or-v1-...",
          help: "From openrouter.ai/keys",
          options: nil
        }
      ],
      capabilities: [:ai_completions, :ai_embeddings],
      instructions: [
        %{
          title: "Create an OpenRouter account",
          steps: [
            {"Go to [openrouter.ai](https://openrouter.ai) and sign up or log in", nil},
            {"Navigate to [Keys](https://openrouter.ai/keys)", nil}
          ]
        },
        %{
          title: "Create an API key",
          steps: [
            {"Click **Create Key**", nil},
            {"Give it a name (e.g., your app name)", nil},
            {"Copy the key and paste it into the form above", nil}
          ]
        },
        %{
          title: "Add credits (optional)",
          steps: [
            {"Some models are free, but most require credits", nil},
            {"Go to [Credits](https://openrouter.ai/credits) to add funds", nil}
          ]
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # External module provider contributions
  # ---------------------------------------------------------------------------

  defp external_providers do
    ModuleRegistry.all_modules()
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :integration_providers, 0) do
        try do
          mod.integration_providers()
        rescue
          e ->
            Logger.warning(
              "[Integrations.Providers] #{inspect(mod)}.integration_providers/0 failed: #{Exception.message(e)}"
            )

            []
        end
      else
        []
      end
    end)
  end

  @doc """
  Returns a map of provider_key => [module_name] showing which modules use each integration.
  """
  @spec used_by_modules() :: %{String.t() => [String.t()]}
  def used_by_modules do
    ModuleRegistry.all_modules()
    |> Enum.reduce(%{}, fn mod, acc ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :required_integrations, 0) do
        try do
          integrations = mod.required_integrations()

          module_name =
            if function_exported?(mod, :module_name, 0), do: mod.module_name(), else: inspect(mod)

          Enum.reduce(integrations, acc, fn key, inner_acc ->
            Map.update(inner_acc, key, [module_name], &[module_name | &1])
          end)
        rescue
          e ->
            Logger.warning(
              "[Integrations.Providers] #{inspect(mod)}.required_integrations/0 failed: #{Exception.message(e)}"
            )

            acc
        end
      else
        acc
      end
    end)
  end
end
