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

  use Gettext, backend: PhoenixKitWeb.Gettext

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
          :key => String.t(),
          :name => String.t(),
          :description => String.t(),
          :icon => String.t(),
          :auth_type => auth_type(),
          :oauth_config => map() | nil,
          :setup_fields => [setup_field()],
          :capabilities => [atom()],
          # `base_url` is the provider's primary REST API base — only the
          # `:ai_completions` providers declare it (used as the default
          # endpoint base by AI consumers). `validation` and `instructions`
          # are present on most built-ins but absent on a few, hence optional.
          optional(:base_url) => String.t(),
          optional(:validation) => map(),
          optional(:instructions) => [map()]
        }

  @providers_cache_key {__MODULE__, :all}
  @used_by_cache_key {__MODULE__, :used_by}

  @doc """
  Returns all known providers, including those contributed by external modules.

  Results are cached in `persistent_term` after the first call.
  Call `clear_cache/0` if modules are added or removed at runtime.
  """
  @spec all() :: [provider()]
  def all do
    case :persistent_term.get(@providers_cache_key, :miss) do
      :miss ->
        providers = builtin_providers() ++ external_providers()
        :persistent_term.put(@providers_cache_key, providers)
        providers

      cached ->
        cached
    end
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

  @doc """
  Returns all providers (built-in + external) that declare the given capability.

  Lets consumers discover providers by what they can do rather than by a
  hardcoded list. For example, an AI module can render its provider picker
  from `with_capability(:ai_completions)`, so adding a new chat provider to
  the registry surfaces it automatically.

  Order follows `all/0` (built-ins first, in definition order).
  """
  @spec with_capability(atom()) :: [provider()]
  def with_capability(capability) when is_atom(capability) do
    Enum.filter(all(), fn p -> capability in (p[:capabilities] || []) end)
  end

  @doc """
  Returns the API base URL declared by a provider, or `nil` if it has none.

  Accepts the same plain or named keys as `get/1` (`"openai"` /
  `"openai:work"`). Only providers with a primary REST API (currently the
  `:ai_completions` providers) declare a `:base_url`; everything else is `nil`.
  """
  @spec base_url(String.t()) :: String.t() | nil
  def base_url(key) when is_binary(key) do
    case get(key) do
      %{base_url: url} when is_binary(url) -> url
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in provider definitions
  # ---------------------------------------------------------------------------

  defp builtin_providers do
    [
      google(),
      microsoft(),
      openai(),
      openrouter(),
      mistral(),
      deepseek(),
      xai(),
      elevenlabs(),
      aws_ses(),
      smtp(),
      brevo_api()
    ]
  end

  defp google do
    %{
      key: "google",
      name: gettext("Google"),
      description: gettext("Google Docs, Drive, Calendar, Sheets, Gmail"),
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
          label: gettext("Client ID"),
          type: :text,
          required: true,
          placeholder: "xxxxx.apps.googleusercontent.com",
          help: gettext("From Google Cloud Console → APIs & Services → Credentials"),
          options: nil
        },
        %{
          key: "client_secret",
          label: gettext("Client Secret"),
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
          title: gettext("Create a Google Cloud project"),
          steps: [
            {gettext("Go to the [Google Cloud Console](https://console.cloud.google.com)"), nil},
            {gettext("Create a new project or select an existing one"), nil}
          ]
        },
        %{
          title: gettext("Enable required APIs"),
          steps: [
            {gettext(
               "Go to [APIs & Services → Library](https://console.cloud.google.com/apis/library)"
             ), nil},
            {gettext("Search for **Google Drive API**, click it, then click **Enable**"), nil},
            {gettext(
               "Go back to the Library and search for **Google Docs API**, click it, then click **Enable**"
             ), nil}
          ],
          note:
            gettext(
              "Drive API handles file listing, creation, copying, and PDF export. Docs API is used for reading document content and substituting template variables."
            )
        },
        %{
          title: gettext("Set up OAuth consent"),
          steps: [
            {gettext(
               "Go to [Branding](https://console.cloud.google.com/auth/branding) in the sidebar — fill in the **App name** and **User support email**, then save"
             ), nil},
            {gettext(
               "Go to [Audience](https://console.cloud.google.com/auth/audience) — set user type to **External** (or Internal for Google Workspace)"
             ), nil},
            {gettext(
               "Still on Audience — while the app is in **Testing** status, add the Google account you will connect as a **Test user** (this must be the same account whose Drive will store your files)"
             ), nil},
            {gettext(
               "Go to [Data Access](https://console.cloud.google.com/auth/scopes) — click **Add or Remove Scopes** and add the Drive and Docs scopes. This step may not be required — the app requests the needed scopes at connect time regardless."
             ), nil}
          ],
          note:
            gettext(
              "Navigate to the OAuth section using the search bar or the hamburger menu: search for \"OAuth\", or go to the sidebar: **APIs & Services → OAuth consent screen**. This opens a different section with its own sidebar."
            )
        },
        %{
          title: gettext("Create an OAuth Client"),
          steps: [
            {gettext(
               "Go to [APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials)"
             ), nil},
            {gettext("Click **Create Credentials → OAuth client ID**"), nil},
            {gettext(
               "Application type: **Web application** (do not select \"Desktop app\" — it won't support redirect URIs)"
             ), nil},
            {gettext("Under **Authorized redirect URIs**, add: `{redirect_uri}`"), nil},
            {gettext("Copy the **Client ID** and **Client Secret** into the form above"), nil}
          ]
        },
        %{
          title: gettext("Connect and authorize"),
          steps: [
            {gettext("Click **Save**, then **Connect Account**"), nil},
            {gettext(
               "Google will show an \"unverified app\" warning — click **Advanced → Go to (app name)** to proceed"
             ), nil},
            {gettext("Grant access to Google Docs and Google Drive"), nil},
            {gettext("You'll be redirected back here once connected"), nil}
          ]
        }
      ]
    }
  end

  defp openai do
    %{
      key: "openai",
      name: gettext("OpenAI"),
      description: gettext("AI models via OpenAI (GPT, embeddings, images, audio)"),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      # Base URL of the OpenAI-compatible chat/completions API. Consumed by
      # AI consumers (e.g. phoenix_kit_ai) as the default endpoint base for
      # `:ai_completions` providers, so the provider list there stays dynamic.
      base_url: "https://api.openai.com/v1",
      # `GET /v1/models` is a lightweight authenticated endpoint — 200 on a
      # valid key, 401 otherwise. OpenAI uses standard `Authorization: Bearer`,
      # so the generic `authenticated_request/4` helper works for consumers too.
      validation: %{
        url: "https://api.openai.com/v1/models",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "sk-...",
          help: gettext("From platform.openai.com/api-keys"),
          options: nil
        }
      ],
      capabilities: [
        :ai_completions,
        :ai_embeddings,
        :image_generation,
        :text_to_speech,
        :speech_to_text
      ],
      instructions: [
        %{
          title: gettext("Create an OpenAI account"),
          steps: [
            {gettext(
               "Go to [platform.openai.com](https://platform.openai.com) and sign up or log in"
             ), nil}
          ]
        },
        %{
          title: gettext("Add credits"),
          steps: [
            {gettext(
               "Go to [Billing](https://platform.openai.com/account/billing/overview) and add a payment method or credits"
             ), nil},
            {gettext(
               "OpenAI requires a positive balance before the API will return completions, even on cheaper models"
             ), nil}
          ]
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Go to [API Keys](https://platform.openai.com/api-keys)"), nil},
            {gettext("Click **Create new secret key**, give it a name"), nil},
            {gettext("Copy the key (shown once) and paste it into the form above"), nil}
          ],
          note:
            gettext(
              "If your account belongs to multiple organizations, keys are scoped to the org selected when the key was created."
            )
        }
      ]
    }
  end

  defp openrouter do
    %{
      key: "openrouter",
      name: gettext("OpenRouter"),
      description: gettext("AI model access via OpenRouter (100+ models)"),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://openrouter.ai/api/v1",
      validation: %{
        url: "https://openrouter.ai/api/v1/auth/key",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "sk-or-v1-...",
          help: gettext("From openrouter.ai/keys"),
          options: nil
        }
      ],
      # `:image_generation` — OpenRouter's catalog includes real image-gen
      # models (Gemini image, GPT-image-1, etc.) at the standard
      # OpenAI-compatible `/images/generations` path.
      capabilities: [:ai_completions, :ai_embeddings, :image_generation],
      instructions: [
        %{
          title: gettext("Create an OpenRouter account"),
          steps: [
            {gettext("Go to [openrouter.ai](https://openrouter.ai) and sign up or log in"), nil},
            {gettext("Navigate to [Keys](https://openrouter.ai/keys)"), nil}
          ]
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Click **Create Key**"), nil},
            {gettext("Give it a name (e.g., your app name)"), nil},
            {gettext("Copy the key and paste it into the form above"), nil}
          ]
        },
        %{
          title: gettext("Add credits (optional)"),
          steps: [
            {gettext("Some models are free, but most require credits"), nil},
            {gettext("Go to [Credits](https://openrouter.ai/credits) to add funds"), nil}
          ]
        }
      ]
    }
  end

  defp mistral do
    %{
      key: "mistral",
      name: gettext("Mistral"),
      description: gettext("AI model access via Mistral AI (Mistral Large, Codestral, Pixtral)"),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://api.mistral.ai/v1",
      validation: %{
        url: "https://api.mistral.ai/v1/models",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "...",
          help: gettext("From console.mistral.ai/api-keys"),
          options: nil
        }
      ],
      capabilities: [:ai_completions, :ai_embeddings],
      instructions: [
        %{
          title: gettext("Create a Mistral account"),
          steps: [
            {gettext(
               "Go to [console.mistral.ai](https://console.mistral.ai) and sign up or log in"
             ), nil},
            {gettext("You may need to verify your phone number before creating API keys"), nil}
          ]
        },
        %{
          title: gettext("Add a payment method (required)"),
          steps: [
            {gettext(
               "Go to [Workspace → Billing](https://console.mistral.ai/billing/plans) and choose **Experiment** (pay-as-you-go) or a paid tier"
             ), nil},
            {gettext("Free models still require a billing-enabled workspace"), nil}
          ],
          note:
            gettext(
              "Mistral does not offer credits without billing setup; this is a hard requirement before keys can be created."
            )
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Go to [API Keys](https://console.mistral.ai/api-keys)"), nil},
            {gettext("Click **Create new key**, give it a name, set an expiry if desired"), nil},
            {gettext("Copy the key (shown once) and paste it into the form above"), nil}
          ]
        }
      ]
    }
  end

  defp deepseek do
    %{
      key: "deepseek",
      name: gettext("DeepSeek"),
      description: gettext("AI model access via DeepSeek (deepseek-chat, deepseek-reasoner)"),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://api.deepseek.com/v1",
      validation: %{
        url: "https://api.deepseek.com/models",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "sk-...",
          help: gettext("From platform.deepseek.com/api_keys"),
          options: nil
        }
      ],
      capabilities: [:ai_completions],
      instructions: [
        %{
          title: gettext("Create a DeepSeek account"),
          steps: [
            {gettext(
               "Go to [platform.deepseek.com](https://platform.deepseek.com) and sign up or log in"
             ), nil}
          ]
        },
        %{
          title: gettext("Add credits"),
          steps: [
            {gettext(
               "Go to [Top up](https://platform.deepseek.com/top_up) and add at least the minimum amount"
             ), nil},
            {gettext(
               "DeepSeek requires a positive balance before you can call the chat or reasoner endpoints, even on cheap models"
             ), nil}
          ]
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Go to [API Keys](https://platform.deepseek.com/api_keys)"), nil},
            {gettext("Click **Create API key**, give it a name"), nil},
            {gettext("Copy the key (shown once) and paste it into the form above"), nil}
          ]
        }
      ]
    }
  end

  defp xai do
    %{
      key: "xai",
      name: gettext("xAI"),
      description: gettext("AI model access via xAI (Grok models)"),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://api.x.ai/v1",
      # xAI's API is OpenAI-compatible. `GET /v1/models` isn't listed on the
      # published API reference but does exist — confirmed 401 (not 404)
      # without a key. Same Bearer-auth pattern as OpenAI/Mistral/DeepSeek.
      validation: %{
        url: "https://api.x.ai/v1/models",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "xai-...",
          help: gettext("From console.x.ai/team/default/api-keys"),
          options: nil
        }
      ],
      # `:realtime_voice` gates the xAI-only streaming TTS panel in
      # phoenix_kit_ai's Playground (Xai.Realtime, WebSocket-based — not
      # reachable through the shared REST completions path).
      # `:image_generation` — xAI's `POST /v1/images/generations` returns
      # the same `data: [{url | b64_json}]` envelope OpenAI's does,
      # despite `grok-imagine-image[-quality]` being invisible to the
      # shared `/models`-based picker's `:image_gen` filter without the
      # xAI-specific no-modality fallback that filter already has.
      capabilities: [:ai_completions, :realtime_voice, :image_generation],
      instructions: [
        %{
          title: gettext("Create an xAI account"),
          steps: [
            {gettext("Go to [accounts.x.ai](https://accounts.x.ai) and sign up or log in"), nil}
          ]
        },
        %{
          title: gettext("Add credits"),
          steps: [
            {gettext("Go to [console.x.ai](https://console.x.ai) → Billing and add credits"),
             nil},
            {gettext("xAI requires a funded account before the API will return completions"), nil}
          ]
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Go to [API Keys](https://console.x.ai/team/default/api-keys)"), nil},
            {gettext("Click **Create API key**, give it a name"), nil},
            {gettext("Copy the key (shown once) and paste it into the form above"), nil}
          ]
        }
      ]
    }
  end

  defp elevenlabs do
    %{
      key: "elevenlabs",
      name: gettext("ElevenLabs"),
      description: gettext("Text-to-speech and voice generation via ElevenLabs"),
      icon: "hero-speaker-wave",
      auth_type: :api_key,
      oauth_config: nil,
      # ElevenLabs authenticates with the API key in a custom `xi-api-key`
      # header (NOT `Authorization: Bearer`). The validation path honors
      # `auth_header`/`auth_prefix`, so Test Connection works. `/v1/user`
      # is a lightweight authenticated GET that returns the account's
      # subscription info — 200 on a valid key, 401 otherwise.
      validation: %{
        url: "https://api.elevenlabs.io/v1/user",
        method: :get,
        auth_header: "xi-api-key",
        auth_prefix: ""
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "sk_...",
          help: gettext("From elevenlabs.io → Settings → API Keys"),
          options: nil
        }
      ],
      capabilities: [:text_to_speech, :speech_to_text, :sound_effects, :music_generation],
      instructions: [
        %{
          title: gettext("Create an ElevenLabs account"),
          steps: [
            {gettext("Go to [elevenlabs.io](https://elevenlabs.io) and sign up or log in"), nil}
          ]
        },
        %{
          title: gettext("Create an API key"),
          steps: [
            {gettext("Go to [Settings → API Keys](https://elevenlabs.io/app/settings/api-keys)"),
             nil},
            {gettext("Click **Create API Key**, give it a name"), nil},
            {gettext("Copy the key (shown once) and paste it into the form above"), nil}
          ],
          note:
            gettext(
              "The free tier includes a monthly character quota; paid plans raise the quota and unlock commercial use and additional voices."
            )
        }
      ]
    }
  end

  defp aws_ses do
    %{
      key: "aws_ses",
      name: gettext("Amazon SES"),
      description: gettext("AWS Simple Email Service (SMTP credentials via SES API)"),
      icon: "hero-envelope",
      auth_type: :key_secret,
      oauth_config: nil,
      # Checked against the SES API itself (GetSendQuota) — see
      # PhoenixKit.Integrations.Validators.
      validation: %{strategy: :aws_ses},
      setup_fields: [
        # Field key is `access_key`, NOT `access_key_id` — the human-facing
        # label still says "Access Key ID". The credential-detection gate
        # (`has_credentials?/1` in integrations.ex) now requires EVERY field a
        # `:key_secret` provider declares `required: true`, so renaming this key
        # without renaming it there leaves SES permanently "not configured".
        %{
          key: "access_key",
          label: gettext("Access Key ID"),
          type: :text,
          required: true,
          placeholder: "AKIA…",
          help: nil,
          options: nil
        },
        %{
          key: "secret_key",
          label: gettext("Secret Access Key"),
          type: :password,
          required: true,
          placeholder: "...",
          help: nil,
          options: nil
        },
        %{
          key: "aws_region",
          label: gettext("Region"),
          type: :text,
          required: true,
          placeholder: "eu-central-1",
          help: nil,
          options: nil
        }
      ],
      capabilities: [:email_send]
    }
  end

  defp smtp do
    %{
      key: "smtp",
      name: gettext("SMTP"),
      description:
        gettext(
          "Universal SMTP relay — works with any vendor (Brevo, Mailgun, SendGrid, a self-hosted mail server, etc). Add one named connection per relay/account."
        ),
      icon: "hero-envelope",
      auth_type: :credentials,
      oauth_config: nil,
      # Checked by opening a real session and authenticating — see
      # PhoenixKit.Integrations.Validators.
      validation: %{strategy: :smtp},
      setup_fields: [
        %{
          key: "host",
          label: gettext("SMTP Host"),
          type: :text,
          required: true,
          placeholder: "smtp-relay.brevo.com",
          help: nil,
          options: nil
        },
        %{
          key: "port",
          label: gettext("Port"),
          type: :number,
          required: true,
          placeholder: "587",
          help: nil,
          options: nil
        },
        %{
          key: "username",
          label: gettext("Username"),
          type: :text,
          required: true,
          placeholder: "your-login@smtp-brevo.com",
          help:
            gettext(
              "For Brevo: your account's SMTP login, shown as <subaccount>@smtp-brevo.com under SMTP & API → SMTP."
            ),
          options: nil
        },
        %{
          key: "password",
          label: gettext("Password"),
          type: :password,
          required: true,
          placeholder: "xsmtpsib-...",
          help:
            gettext(
              "For Brevo: the SMTP key starting with xsmtpsib- (SMTP & API → SMTP tab) — not the API key (xkeysib-)."
            ),
          options: nil
        }
      ],
      capabilities: [:email_send]
    }
  end

  defp brevo_api do
    %{
      key: "brevo_api",
      name: gettext("Brevo API"),
      description: gettext("Send email via the Brevo transactional email API"),
      icon: "hero-envelope",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://api.brevo.com/v3",
      # Makes "Test Connection" tell the truth for this provider: without a
      # validation map `do_validate/2` falls through to `:ok` and stamps the
      # connection "connected" without ever checking the key. Brevo
      # authenticates with a bare `api-key` header (no Bearer prefix).
      validation: %{
        url: "https://api.brevo.com/v3/account",
        method: :get,
        auth_header: "api-key",
        auth_prefix: ""
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "xkeysib-...",
          help:
            gettext(
              "From Brevo → SMTP & API → API Keys. Starts with xkeysib- — not the SMTP key (xsmtpsib-)."
            ),
          options: nil
        }
      ],
      capabilities: [:email_send]
    }
  end

  defp microsoft do
    %{
      key: "microsoft",
      name: gettext("Microsoft 365"),
      description: gettext("Microsoft Graph — Outlook, OneDrive, Teams, Calendar, SharePoint"),
      icon: "hero-cloud",
      auth_type: :oauth2,
      oauth_config: %{
        # `{tenant_id}` is templated at request time from
        # `integration_data["tenant_id"]` (per-connection setup field) or
        # the `:url_defaults` fallback below. `common` accepts both
        # work-or-school AND personal accounts; single-tenant apps must
        # set the GUID, `consumers`, or `organizations`.
        auth_url: "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/authorize",
        token_url: "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        url_defaults: %{"tenant_id" => "common"},
        userinfo_url: "https://graph.microsoft.com/v1.0/me",
        # `offline_access` is required for refresh tokens — without it
        # the access token expires after ~1h and there's no way back.
        # `User.Read` is the minimum needed for /me to return a profile.
        # Add Mail.Read, Files.Read.All, Calendars.Read, etc. as the
        # consumer module needs them; Microsoft requires the app
        # registration's API permissions to match what's requested here.
        default_scopes: "openid email profile offline_access User.Read",
        # `prompt=consent` forces the consent screen so refresh_token
        # is reliably issued on every connect (Microsoft sometimes
        # silently drops it on re-auth without this).
        auth_params: %{"prompt" => "consent"}
      },
      setup_fields: [
        %{
          key: "client_id",
          label: gettext("Application (client) ID"),
          type: :text,
          required: true,
          placeholder: "00000000-0000-0000-0000-000000000000",
          help: gettext("From Azure Portal → App registrations → your app → Overview"),
          options: nil
        },
        %{
          key: "client_secret",
          label: gettext("Client Secret"),
          type: :password,
          required: true,
          placeholder: "...",
          help:
            gettext(
              "From your app → Certificates & secrets → New client secret. Copy the *Value*, not the Secret ID."
            ),
          options: nil
        },
        %{
          key: "tenant_id",
          label: gettext("Tenant ID"),
          type: :text,
          required: false,
          placeholder: "common",
          help:
            gettext(
              "Leave as `common` for multi-tenant + personal accounts. For single-tenant apps, paste your Directory (tenant) ID GUID. Use `consumers` for personal-only or `organizations` for any work-or-school account."
            ),
          options: nil
        }
      ],
      capabilities: [
        :microsoft_outlook,
        :microsoft_onedrive,
        :microsoft_teams,
        :microsoft_calendar
      ],
      instructions: [
        %{
          title: gettext("Register an application in Microsoft Entra ID (Azure AD)"),
          steps: [
            {gettext(
               "Go to the [Azure Portal](https://portal.azure.com) and search for **App registrations**"
             ), nil},
            {gettext("Click **New registration**, give the app a name"), nil},
            {gettext(
               "Under **Supported account types**, choose the audience: *Personal Microsoft accounts only*, *Accounts in any organizational directory*, or *Accounts in this organizational directory only* depending on who should sign in"
             ), nil},
            {gettext("Under **Redirect URI**, choose **Web** and enter: `{redirect_uri}`"), nil},
            {gettext("Click **Register**"), nil}
          ],
          note:
            gettext(
              "If you picked a single-tenant audience, fill in **Tenant ID** above with your Directory (tenant) ID GUID — leaving it as `common` only works for multi-tenant + personal apps."
            )
        },
        %{
          title: gettext("Add a client secret"),
          steps: [
            {gettext("Go to **Certificates & secrets → New client secret**"), nil},
            {gettext("Set an expiration (24 months is common; renew before it lapses)"), nil},
            {gettext(
               "Copy the **Value** column (not the Secret ID) into the form above — the value is shown ONCE and disappears on page refresh"
             ), nil}
          ]
        },
        %{
          title: gettext("Configure API permissions"),
          steps: [
            {gettext(
               "Go to **API permissions → Add a permission → Microsoft Graph → Delegated permissions**"
             ), nil},
            {gettext(
               "Add the permissions your integration needs: `User.Read` is included by default; add `Mail.Read`, `Files.Read.All`, `Calendars.Read`, etc. as required"
             ), nil},
            {gettext(
               "If your tenant requires admin consent, click **Grant admin consent for <tenant>** before the connect flow will work"
             ), nil}
          ],
          note:
            gettext(
              "The `default_scopes` in the provider definition request `openid email profile offline_access User.Read` — extra scopes can be added per-connect by passing `extra_scopes` to `authorization_url/5`."
            )
        },
        %{
          title: gettext("Connect and authorize"),
          steps: [
            {gettext("Click **Save**, then **Connect Account**"), nil},
            {gettext(
               "Microsoft will show the consent screen — click **Accept** to grant the requested permissions"
             ), nil},
            {gettext("You'll be redirected back here once connected"), nil}
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
  Clears the cached provider list and used-by map.

  Call this when modules are added or removed at runtime so the next
  call to `all/0` or `used_by_modules/0` recomputes from the module registry.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@providers_cache_key)
    :persistent_term.erase(@used_by_cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns a map of provider_key => [module_name] showing which modules use each integration.
  """
  @spec used_by_modules() :: %{String.t() => [String.t()]}
  def used_by_modules do
    case :persistent_term.get(@used_by_cache_key, :miss) do
      :miss ->
        result = compute_used_by_modules()
        :persistent_term.put(@used_by_cache_key, result)
        result

      cached ->
        cached
    end
  end

  defp compute_used_by_modules do
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
