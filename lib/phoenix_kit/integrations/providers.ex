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
          optional(:instructions) => [map()],
          # A module that shapes the setup form from what has been typed so far
          # (`setup_fields/2`, `setup_attrs/2`, `setup_changed/3`,
          # `setup_saved/3` below call it). `setup_fields` stays the provider's
          # static declaration — which keys exist and which are required —
          # while the module decides which of them a form shows.
          optional(:setup_module) => module(),
          # Which integration surfaces may hold a connection for this provider.
          # `:system` = the website-wide setup; `:personal` = a user's own
          # setup. Absent ⇒ `[:system]` (a provider opts INTO personal use
          # explicitly — the self-owned-secret providers do; OAuth2 providers,
          # whose setup fields are the APP's client_id/secret, stay system-only).
          optional(:scopes) => [:system | :personal],
          # `true`: offered to users on the personal "add" picker until a site
          # admin saves their own choice (Settings → Integrations → Personal
          # integrations). It is how a provider says "I was offered to users
          # before that choice existed", so no central list names them.
          optional(:personal_default) => boolean(),
          # A boolean setting key: the provider is ALSO offered to users while
          # that setting is on, whatever the admin's list says (Object Storage
          # while users may keep a library on their own bucket: without a
          # connection that feature is a dead end).
          optional(:personal_also_while) => String.t()
        }

  @providers_cache_key {__MODULE__, :all}
  @used_by_cache_key {__MODULE__, :used_by}

  @doc """
  Returns all known providers, including those contributed by external modules.

  Results are cached in `persistent_term` after the first call.
  `PhoenixKit.ModuleRegistry` calls `clear_cache/0` for you whenever the
  registered-module set changes (`register/1`, `unregister/1`, `rescan/0`),
  so a module discovered after the cache was warmed still contributes its
  providers. Call it yourself only when something outside the registry
  changes what `integration_providers/0` would return.
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

  @doc """
  The scopes a provider may hold a connection under. Defaults to `[:system]`
  when the provider omits `:scopes` (so an external module's provider never
  lands on the personal page unless it opts in).
  """
  @spec scopes_of(String.t() | provider()) :: [:system | :personal]
  def scopes_of(%{} = provider), do: normalize_scopes(provider[:scopes])
  def scopes_of(key) when is_binary(key), do: scopes_of(get(key) || %{})

  defp normalize_scopes(scopes) when is_list(scopes) do
    case Enum.filter(scopes, &(&1 in [:system, :personal])) do
      [] -> [:system]
      list -> list
    end
  end

  defp normalize_scopes(_), do: [:system]

  @doc """
  All providers usable under `scope` (`:system` or `:personal`).

  Drives the provider grid on each page — the system setup lists
  `for_scope(:system)`, the personal setup lists `for_scope(:personal)`.
  """
  @spec for_scope(:system | :personal) :: [provider()]
  def for_scope(scope) when scope in [:system, :personal] do
    Enum.filter(all(), fn p -> scope in scopes_of(p) end)
  end

  @personal_setting "personal_integration_providers"

  @doc """
  Providers offered on the personal integrations "add" picker: the providers that
  may be personal (`for_scope(:personal)`) and that a site admin has enabled for
  users (`personal_enabled_keys/0`), plus any that declares
  `:personal_also_while` and whose setting is on. Returned in `for_scope/1`'s order.
  """
  @spec personal_offered() :: [provider()]
  def personal_offered do
    capable = for_scope(:personal)
    enabled = personal_enabled_keys(capable)

    Enum.filter(capable, &(&1.key in enabled or also_while_on?(&1)))
  end

  @doc """
  The provider keys a site admin has enabled for users. Until one saves a choice
  (`put_personal_enabled/1`) they are the providers that declare
  `:personal_default`, which is what users were offered before the choice existed.
  """
  @spec personal_enabled_keys([provider()]) :: [String.t()]
  def personal_enabled_keys(capable \\ for_scope(:personal)) do
    case PhoenixKit.Settings.get_json_setting_cached(@personal_setting, nil) do
      %{"providers" => keys} when is_list(keys) ->
        Enum.filter(keys, &is_binary/1)

      _ ->
        for p <- capable, p[:personal_default] == true, do: p.key
    end
  end

  @doc """
  Saves which providers users may add on their own. Only providers that may be
  personal are kept; everything else in `keys` is dropped.
  """
  @spec put_personal_enabled([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def put_personal_enabled(keys) when is_list(keys) do
    capable = Enum.map(for_scope(:personal), & &1.key)
    kept = keys |> Enum.filter(&(&1 in capable)) |> Enum.uniq()

    case PhoenixKit.Settings.update_json_setting(@personal_setting, %{"providers" => kept}) do
      {:ok, _setting} -> {:ok, kept}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether `provider` is offered to users only because a setting it names is on."
  @spec also_while_on?(provider()) :: boolean()
  def also_while_on?(%{personal_also_while: setting}) when is_binary(setting),
    do: PhoenixKit.Settings.get_boolean_setting(setting, false)

  def also_while_on?(_provider), do: false

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
      amazon_bedrock(),
      aws_ses(),
      object_storage(),
      smtp(),
      brevo_api(),
      telegram(),
      github(),
      dataforseo(),
      serpapi()
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
      scopes: [:system, :personal],
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
      scopes: [:system, :personal],
      personal_default: true,
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
      scopes: [:system, :personal],
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
      scopes: [:system, :personal],
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
      scopes: [:system, :personal],
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
      scopes: [:system, :personal],
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

  # Bedrock's OpenAI-compatible chat endpoint is regional, but the registry
  # `base_url` is static — the default below matches our primary region, and
  # the AI endpoint form lets the operator override `base_url` per endpoint.
  # Auth is a long-term Bedrock API key (plain Bearer, no SigV4) — the same
  # header the OpenAI-compatible runtime endpoint accepts, so one credential
  # serves both the validation probe and real completions.
  defp amazon_bedrock do
    %{
      key: "amazon_bedrock",
      scopes: [:system, :personal],
      name: gettext("Amazon Bedrock"),
      description:
        gettext(
          "AWS Bedrock LLMs via a Bedrock API key (OpenAI-compatible endpoint: gpt-oss models; the rest via native Converse)"
        ),
      icon: "hero-sparkles",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://bedrock-runtime.eu-central-1.amazonaws.com/openai/v1",
      # Region-aware — checked against the Bedrock control plane itself
      # (ListFoundationModels), see PhoenixKit.Integrations.Validators.
      validation: %{strategy: :amazon_bedrock},
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("Bedrock API key"),
          type: :password,
          required: true,
          placeholder: "ABSK…",
          help: gettext("AWS console → Amazon Bedrock → API keys (long-term key)"),
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
      capabilities: [:ai_completions],
      instructions: [
        %{
          title: gettext("Create a Bedrock API key"),
          steps: [
            {gettext(
               "Open the [Bedrock console → API keys](https://console.aws.amazon.com/bedrock/home#/api-keys) and generate a **long-term** key (docs: [Bedrock API keys](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html))"
             ), nil},
            {gettext(
               "Or attach one to an existing IAM user: [IAM console](https://console.aws.amazon.com/iam/home#/users) → user → Security credentials → Bedrock API keys"
             ), nil},
            {gettext("Copy the key (shown once, `ABSK…`) and paste it into the form above"), nil}
          ],
          note:
            gettext(
              "The key's IAM identity must allow the `bedrock:CallWithBearerToken` action — without it every Bearer call answers 403 even when invoke permissions are in place."
            )
        },
        %{
          title: gettext("Enable model access"),
          steps: [
            {gettext(
               "In [Bedrock → Model access](https://console.aws.amazon.com/bedrock/home#/modelaccess) enable the models you plan to call — a key with no enabled models validates but cannot complete"
             ), nil},
            {gettext(
               "Pick the region where access was granted; the AI endpoint's base URL must use the same region"
             ), nil}
          ]
        },
        %{
          title: gettext("Use it from the AI module"),
          steps: [
            {gettext(
               "The OpenAI-compatible endpoint (`…/openai/v1`) currently serves only the `openai.gpt-oss-*` models — Anthropic and the other Bedrock models answer on the native Converse API with the same key"
             ), nil},
            {gettext(
               "In the AI module, create an endpoint pointing at this connection with a `gpt-oss` model and a base URL in the SAME region as this key"
             ), nil}
          ]
        }
      ]
    }
  end

  # A read-only token for GitHub API consumers (e.g. org-statistics dashboard
  # widgets). GraphQL requires authentication even for public data, so the
  # least-privilege credential is a fine-grained PAT with public-repo
  # read-only access.
  defp github do
    %{
      key: "github",
      scopes: [:system, :personal],
      name: gettext("GitHub"),
      description:
        gettext("GitHub API token — org statistics, repositories (read-only is enough)"),
      icon: "hero-code-bracket-square",
      auth_type: :api_key,
      oauth_config: nil,
      # 200 with a valid token, 401 otherwise; standard Bearer auth.
      validation: %{
        url: "https://api.github.com/rate_limit",
        method: :get,
        auth_header: "Authorization",
        auth_prefix: "Bearer "
      },
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("Personal access token"),
          type: :password,
          required: true,
          placeholder: "github_pat_… / ghp_…",
          help: gettext("github.com/settings/personal-access-tokens — fine-grained, read-only"),
          options: nil
        }
      ],
      capabilities: [:github_api],
      instructions: [
        %{
          title: gettext("Create a token"),
          steps: [
            {gettext(
               "Go to [Fine-grained tokens](https://github.com/settings/personal-access-tokens) and click **Generate new token**"
             ), nil},
            {gettext(
               "Repository access: **Public repositories (read-only)** — no extra permissions needed for public-org statistics"
             ), nil},
            {gettext("Copy the token and paste it into the form above"), nil}
          ]
        }
      ]
    }
  end

  defp aws_ses do
    %{
      key: "aws_ses",
      scopes: [:system, :personal],
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
      capabilities: [:email_send],
      instructions: [
        %{
          title: gettext("Create an IAM user with SES access"),
          steps: [
            {gettext(
               "In the [IAM console](https://console.aws.amazon.com/iam/home#/users) create a user for programmatic access and attach an SES policy (least privilege: `ses:SendEmail`/`ses:SendRawEmail`; docs: [SES setup](https://docs.aws.amazon.com/ses/latest/dg/setting-up.html))"
             ), nil},
            {gettext(
               "Create an access key for that user (Security credentials → Create access key) and paste the ID and secret above"
             ), nil}
          ]
        },
        %{
          title: gettext("Verify a sender in SES"),
          steps: [
            {gettext(
               "In the [SES console](https://console.aws.amazon.com/ses/home#/identities) verify your domain or sender address — SES refuses to send from unverified identities"
             ), nil},
            {gettext(
               "New accounts start in the SES sandbox (verified recipients only) — [request production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html) before real sending"
             ), nil}
          ],
          note:
            gettext(
              "This connection stores the credential. The full sending pipeline — configuration set, SNS topic, SQS event queue, delivery tracking — is configured in Admin → Settings → Emails, which can select this connection as its credential source."
            )
        }
      ]
    }
  end

  # Deliberately separate from `aws_ses` even though both are `:key_secret`
  # AWS-shaped credentials: one pair of keys sends mail, the other reads/writes
  # a bucket, and an operator must be able to rotate or revoke either without
  # touching the other. `object_storage` (not `aws_s3`) because the same shape
  # of credential — access key + secret + optional region/endpoint — also
  # covers Cloudflare R2, Backblaze B2, and Tigris, mirroring the same
  # provider-per-protocol generalization `PhoenixKit.Modules.Storage.Bucket`
  # already makes for those four (`lib/modules/storage/schemas/bucket.ex`).
  defp object_storage do
    %{
      key: "object_storage",
      scopes: [:system, :personal],
      personal_also_while: "storage_user_buckets_enabled",
      name: gettext("Object Storage (S3-compatible)"),
      description:
        gettext(
          "S3-compatible object storage — AWS S3, Cloudflare R2, Backblaze B2, Tigris, or a self-hosted endpoint"
        ),
      icon: "hero-circle-stack",
      auth_type: :key_secret,
      oauth_config: nil,
      # Checked against the storage API itself (ListBuckets) — see
      # PhoenixKit.Integrations.Validators.
      validation: %{strategy: :object_storage},
      # The form opens on a choice of service and asks only what that service
      # needs; the fields below are what a connection stores.
      setup_module: PhoenixKit.Integrations.ObjectStorageServices,
      setup_fields: [
        %{
          key: "service",
          label: gettext("Service"),
          type: :select,
          required: false,
          placeholder: nil,
          help: nil,
          options: nil
        },
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
          key: "region",
          label: gettext("Region"),
          type: :text,
          required: false,
          placeholder: "eu-central-1",
          help:
            gettext(
              "Not every S3-compatible provider needs one — leave blank if the endpoint doesn't require it."
            ),
          options: nil
        },
        %{
          key: "endpoint",
          label: gettext("Endpoint"),
          type: :text,
          required: false,
          placeholder: "s3.us-west-002.backblazeb2.com",
          help:
            gettext(
              "Required for Cloudflare R2, Backblaze B2, Tigris, and self-hosted S3-compatible storage. Leave blank for AWS S3."
            ),
          options: nil
        },
        # Remembered so an edit shows what was chosen; the endpoint is built
        # from them (see `ObjectStorageServices`).
        %{
          key: "account_id",
          label: gettext("Account ID"),
          type: :text,
          required: false,
          placeholder: nil,
          help: nil,
          options: nil
        },
        %{
          key: "jurisdiction",
          label: gettext("Jurisdiction"),
          type: :text,
          required: false,
          placeholder: nil,
          help: nil,
          options: nil
        }
      ],
      capabilities: [:object_storage]
    }
  end

  defp smtp do
    %{
      key: "smtp",
      scopes: [:system, :personal],
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
        # Optional, not required: an internal relay that authenticates by IP has
        # no login to give, and `PhoenixKit.Mailer.SmtpTransport` has always had
        # a credential-less branch (opportunistic TLS, degrade instead of
        # :no_ca_store). Marking these required made that branch — and the
        # `auth: never` / `security: none` settings below — impossible to reach
        # from the form. The absent `*` is the UI signal; the help strings are
        # left exactly as they were rather than gaining a "leave blank" sentence,
        # because editing a translated msgid orphans it in all eight locales.
        %{
          key: "username",
          label: gettext("Username"),
          type: :text,
          required: false,
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
          required: false,
          placeholder: "xsmtpsib-...",
          help:
            gettext(
              "For Brevo: the SMTP key starting with xsmtpsib- (SMTP & API → SMTP tab) — not the API key (xkeysib-)."
            ),
          options: nil
        },
        # Everything below is optional and blank by default, which keeps an
        # existing connection behaving exactly as it did when the port was the
        # only signal. See PhoenixKit.Mailer.SmtpTransport for how each is
        # applied — the send path and the Test Connection probe read the same
        # options, so a relay that tests green sends green.
        %{
          key: "security",
          label: gettext("Encryption"),
          type: :select,
          required: false,
          placeholder: nil,
          help:
            gettext(
              "Auto follows the port: 465 means implicit TLS, anything else STARTTLS (required when a login is set). Choose explicitly for a relay that ignores that convention."
            ),
          options: [
            %{value: "auto", label: gettext("Auto (from port)")},
            %{value: "ssl", label: gettext("Implicit TLS / SMTPS")},
            %{value: "starttls", label: gettext("STARTTLS — required")},
            %{value: "starttls_optional", label: gettext("STARTTLS — if offered")},
            %{value: "none", label: gettext("None — plaintext")}
          ]
        },
        %{
          key: "auth",
          label: gettext("Authentication"),
          type: :select,
          required: false,
          placeholder: nil,
          help:
            gettext(
              "Whether to send the login at all. “If offered” follows the relay; “Never” is for relays that authenticate by IP."
            ),
          options: [
            %{value: "if_available", label: gettext("If offered (default)")},
            %{value: "always", label: gettext("Always")},
            %{value: "never", label: gettext("Never")}
          ]
        },
        %{
          key: "verify_cert",
          label: gettext("Certificate verification"),
          type: :select,
          required: false,
          placeholder: nil,
          help:
            gettext(
              "Turning verification off means the login travels to whoever answers, including an impostor. Use a CA certificate below instead whenever you can."
            ),
          options: [
            %{value: "verify_peer", label: gettext("Verify (default)")},
            %{value: "verify_none", label: gettext("Do not verify")}
          ]
        },
        %{
          key: "ca_cert",
          label: gettext("CA certificate (PEM)"),
          type: :textarea,
          required: false,
          placeholder: "-----BEGIN CERTIFICATE-----",
          help:
            gettext(
              "For a private or self-signed relay certificate. Replaces the system CA store for this connection only."
            ),
          options: nil
        },
        %{
          key: "timeout",
          label: gettext("Timeout (seconds)"),
          type: :number,
          required: false,
          placeholder: "30",
          help: gettext("Leave blank for the gen_smtp default."),
          options: nil
        }
      ],
      capabilities: [:email_send]
    }
  end

  defp brevo_api do
    %{
      key: "brevo_api",
      scopes: [:system, :personal],
      name: gettext("Brevo API"),
      description: gettext("Send email via the Brevo transactional email API"),
      icon: "hero-envelope",
      auth_type: :api_key,
      oauth_config: nil,
      base_url: "https://api.brevo.com/v3",
      # Makes "Test Connection" tell the truth for this provider: without a
      # validation map `do_validate/2` falls through to `:ok` and stamps the
      # connection "connected" without ever checking the key. Checked against
      # the account endpoint itself, which also reports remaining credits —
      # see PhoenixKit.Integrations.Validators.brevo_api/1.
      validation: %{strategy: :brevo_api},
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

  defp telegram do
    %{
      key: "telegram",
      # Available both website-wide (a project bot) and personal (a user's own
      # bot for notifications).
      scopes: [:system, :personal],
      personal_default: true,
      name: gettext("Telegram"),
      description: gettext("Send messages and notifications via your own Telegram bot"),
      icon: "hero-paper-airplane",
      auth_type: :bot_token,
      oauth_config: nil,
      # Telegram embeds the token in the URL path (`/bot<token>/getMe`), not a
      # header, so it declares a strategy instead of the header-based shape the
      # generic api_key/bot_token check builds.
      validation: %{strategy: :telegram},
      setup_fields: [
        %{
          key: "bot_token",
          label: gettext("Bot Token"),
          type: :password,
          required: true,
          placeholder: "123456789:ABCdef...",
          help: gettext("From @BotFather → /newbot (or /token for an existing bot)"),
          options: nil
        }
      ],
      capabilities: [:messaging],
      instructions: [
        %{
          title: gettext("Create a bot with BotFather"),
          steps: [
            {gettext("Open [@BotFather](https://t.me/BotFather) in Telegram"), nil},
            {gettext("Send **/newbot** and follow the prompts to name your bot"), nil}
          ]
        },
        %{
          title: gettext("Copy the bot token"),
          steps: [
            {gettext(
               "BotFather replies with an HTTP API token like `123456789:ABCdef...` — copy it"
             ), nil},
            {gettext("Paste the token into the form above and press **Test Connection**"), nil}
          ]
        },
        # A valid token delivers nothing on its own: Telegram forbids a bot from
        # messaging first, so every destination has to be linked explicitly.
        %{
          title: gettext("Link the chats the bot will message"),
          steps: [
            {gettext("Send **/start** to your bot in Telegram, then press **Test Connection**"),
             nil},
            {gettext(
               "For a group: add the bot to the group, send **/start@yourbotname** there, then press **Test Connection** — a bot cannot read ordinary group messages, only commands addressed to it"
             ), nil},
            {gettext("A chat id you already know can be typed into **Link a chat by ID**"), nil}
          ]
        }
      ]
    }
  end

  # Search-engine results (SERP) providers. Both are billed per search from an
  # account balance or a monthly quota, so their checks call the free account
  # endpoint and report what is left — see PhoenixKit.Integrations.Validators.
  #
  # DataForSEO authenticates with HTTP Basic: the account's API login (its
  # e-mail) and a generated API password that is NOT the password used to sign
  # in to their site. `:key_secret` with both fields required, so
  # `has_credentials?/1` waits for the pair; `password` is one of
  # `Encryption.sensitive_fields/0`, the login is not a secret.
  defp dataforseo do
    %{
      key: "dataforseo",
      scopes: [:system],
      name: gettext("DataForSEO"),
      description:
        gettext("Search engine results, keyword and SEO data — pay as you go per request"),
      icon: "hero-presentation-chart-line",
      auth_type: :key_secret,
      oauth_config: nil,
      validation: %{strategy: :dataforseo},
      setup_fields: [
        %{
          key: "login",
          label: gettext("API login"),
          type: :text,
          required: true,
          placeholder: "you@example.com",
          help: gettext("The e-mail address of your DataForSEO account"),
          options: nil
        },
        %{
          key: "password",
          label: gettext("API password"),
          type: :password,
          required: true,
          placeholder: "...",
          help:
            gettext("From app.dataforseo.com → API Access. Not the password you sign in with."),
          options: nil
        }
      ],
      capabilities: [:search_results, :seo_data],
      instructions: [
        %{
          title: gettext("Get your API login and password"),
          steps: [
            {gettext(
               "Create an account at [DataForSEO](https://app.dataforseo.com/register) — new accounts start with a small trial balance"
             ), nil},
            {gettext(
               "Open [API Access](https://app.dataforseo.com/api-access): the API login is your account e-mail, and the API password is shown there"
             ), nil},
            {gettext(
               "The API password is generated for you and differs from your sign-in password. After the first day it is no longer shown — use **Send by e-mail** on the same page to get it"
             ), nil},
            {gettext("Paste both into the form above and press **Test Connection**"), nil}
          ],
          note:
            gettext(
              "Test Connection is free and shows the account balance. Every search is paid from that balance, so top it up on app.dataforseo.com before it runs out."
            )
        }
      ]
    }
  end

  # SerpApi takes its key as an `api_key` query parameter rather than a header,
  # so it declares a strategy instead of the generic header-based check.
  defp serpapi do
    %{
      key: "serpapi",
      scopes: [:system],
      name: gettext("SerpApi"),
      description: gettext("Search engine results — a monthly plan of searches"),
      icon: "hero-magnifying-glass",
      auth_type: :api_key,
      oauth_config: nil,
      validation: %{strategy: :serpapi},
      setup_fields: [
        %{
          key: "api_key",
          label: gettext("API Key"),
          type: :password,
          required: true,
          placeholder: "...",
          help: gettext("From serpapi.com/manage-api-key"),
          options: nil
        }
      ],
      capabilities: [:search_results],
      instructions: [
        %{
          title: gettext("Get your API key"),
          steps: [
            {gettext(
               "Sign up at [SerpApi](https://serpapi.com) — the free plan includes a number of searches each month"
             ), nil},
            {gettext(
               "Copy the key from [API Key](https://serpapi.com/manage-api-key) and paste it into the form above"
             ), nil}
          ],
          note:
            gettext(
              "Test Connection does not use up a search. It shows your plan and how many searches are left."
            )
        }
      ]
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

  # ---------------------------------------------------------------------------
  # Setup form
  #
  # The two integration forms (admin and personal) render and save through
  # these, so a provider that shapes its form (`:setup_module`) does so in both
  # and the persisted-keys rule lives in one place.
  # ---------------------------------------------------------------------------

  @doc """
  The setup fields a form shows. `values` are the saved and typed values merged
  (typed over saved); a provider without a `:setup_module` always shows its
  declared `setup_fields`.
  """
  @spec setup_fields(provider(), map()) :: [map()]
  def setup_fields(provider, values \\ %{})

  def setup_fields(%{setup_module: module}, values) when is_atom(module),
    do: module.fields(values)

  def setup_fields(%{setup_fields: fields}, _values) when is_list(fields), do: fields
  def setup_fields(_provider, _values), do: []

  @doc "Whether the form's fields depend on what has been typed."
  @spec dynamic_setup?(provider() | nil) :: boolean()
  def dynamic_setup?(%{setup_module: module}) when is_atom(module), do: true
  def dynamic_setup?(_provider), do: false

  @doc """
  The attributes to save for a submitted form. Only keys the provider declares
  are kept, so form params cannot add keys to the stored data. Blanks are
  dropped for `:password` fields only: an untouched secret (never re-rendered)
  must not be blanked by submitting the form, while a cleared optional field
  must clear.
  """
  @spec setup_attrs(provider() | nil, map()) :: map()
  def setup_attrs(%{setup_module: module}, params) when is_atom(module),
    do: module.attrs(params)

  def setup_attrs(%{setup_fields: fields}, params) when is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value = params[field.key] |> to_string() |> String.trim()

      if Map.get(field, :type) == :password and value == "",
        do: acc,
        else: Map.put(acc, field.key, value)
    end)
  end

  def setup_attrs(_provider, _params), do: %{}

  @doc """
  The typed values once `incoming` (the form as just sent, declared keys only)
  arrives over `previous`. Providers without a `:setup_module` just merge.
  """
  @spec setup_changed(provider() | nil, map(), map()) :: map()
  def setup_changed(%{setup_module: module}, previous, incoming) when is_atom(module),
    do: module.changed(previous, incoming)

  def setup_changed(_provider, previous, incoming), do: Map.merge(previous, incoming)

  @doc """
  What kind of account a connection is, for a provider whose one entry covers
  many (Object Storage: Tigris, Cloudflare R2, …) — shown next to the provider
  name in the lists, since "Object Storage (S3-compatible)" alone does not say
  which. nil when the provider has nothing to add.
  """
  @spec setup_label(provider() | nil, map()) :: String.t() | nil
  def setup_label(%{setup_module: module}, data) when is_atom(module) and is_map(data) do
    if Code.ensure_loaded?(module) and function_exported?(module, :label, 1),
      do: module.label(data)
  end

  def setup_label(_provider, _data), do: nil

  @doc """
  The saved values a form may show next to the typed ones (see
  `ObjectStorageServices.saved/2`).
  """
  @spec setup_saved(provider() | nil, map(), map()) :: map()
  def setup_saved(%{setup_module: module}, data, typed) when is_atom(module),
    do: module.saved(data, typed)

  def setup_saved(_provider, data, _typed), do: data

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
