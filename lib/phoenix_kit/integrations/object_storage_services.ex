defmodule PhoenixKit.Integrations.ObjectStorageServices do
  @moduledoc """
  The service-by-service setup form of the `object_storage` integration.

  "S3-compatible" is a protocol, not a place to connect to: the same access key
  and secret reach Amazon S3, Cloudflare R2, Backblaze B2, Hetzner Object
  Storage, Tigris, Wasabi, DigitalOcean Spaces and a self-hosted MinIO, but what else the form must ask
  differs for each (a region you pick, an account id the endpoint is built from,
  nothing at all), and what the endpoint is differs too. The form therefore
  opens on a choice of service and shows only the fields that service needs.

  What is *stored* does not change: `access_key`, `secret_key`, `region` and
  `endpoint` (everything that reads a connection — the validator, a bucket —
  keeps reading those four). The form works out `region` and `endpoint` from
  what the service asks: a Backblaze region becomes
  `s3.<region>.backblazeb2.com`, a Hetzner location becomes
  `<location>.your-objectstorage.com`, an R2 account id becomes
  `<account>.r2.cloudflarestorage.com`. Three more keys remember what was
  chosen so an edit shows it again: `service`, `account_id` and `jurisdiction`.

  A connection saved before the choice existed has no `service`; `current/1`
  infers it from the endpoint, so an old Backblaze connection opens as Backblaze
  and nothing has to be migrated.

  This module is the provider's `:setup_module`: `PhoenixKit.Integrations.Providers`
  calls `fields/1`, `attrs/1`, `changed/2` and `saved/2`, and the two integration
  forms go through those, so the admin and the personal form cannot drift.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.Endpoint

  @type values :: %{optional(String.t()) => term()}

  @services ~w(aws_s3 cloudflare_r2 backblaze_b2 hetzner tigris wasabi digitalocean_spaces other)

  # Keys a service may leave behind that another service must not inherit.
  @service_keys ~w(region endpoint account_id jurisdiction)

  # What a region name may look like before it is put into a host name.
  @region_format ~r/\A[a-z0-9][a-z0-9-]{0,40}\z/

  # Not in `BackblazeRegions`/other libraries: the codes a provider's own page
  # shows as the middle of its endpoint. A combo (free text + suggestions), not
  # a closed list, because these grow faster than a library is released.
  @wasabi_regions [
    {"us-east-1", "N. Virginia"},
    {"us-east-2", "N. Virginia 2"},
    {"us-central-1", "Texas"},
    {"us-west-1", "Oregon"},
    {"ca-central-1", "Toronto"},
    {"eu-central-1", "Amsterdam"},
    {"eu-central-2", "Frankfurt"},
    {"eu-west-1", "London"},
    {"eu-west-2", "Paris"},
    {"eu-south-1", "Milan"},
    {"ap-northeast-1", "Tokyo"},
    {"ap-northeast-2", "Osaka"},
    {"ap-southeast-1", "Singapore"},
    {"ap-southeast-2", "Sydney"}
  ]

  # Hetzner's Object Storage locations; the code is both the endpoint's first
  # label and the signing region.
  @hetzner_locations [
    {"fsn1", "Falkenstein"},
    {"nbg1", "Nuremberg"},
    {"hel1", "Helsinki"}
  ]

  @spaces_regions [
    {"nyc3", "New York 3"},
    {"sfo3", "San Francisco 3"},
    {"sfo2", "San Francisco 2"},
    {"tor1", "Toronto"},
    {"atl1", "Atlanta"},
    {"ams3", "Amsterdam 3"},
    {"lon1", "London"},
    {"fra1", "Frankfurt"},
    {"blr1", "Bangalore"},
    {"sgp1", "Singapore"},
    {"syd1", "Sydney"}
  ]

  # ---------------------------------------------------------------------------
  # The services
  # ---------------------------------------------------------------------------

  @doc "The service keys, in the order the form lists them."
  @spec service_keys() :: [String.t()]
  def service_keys, do: @services

  @doc "A service's name."
  @spec name(String.t()) :: String.t()
  def name("aws_s3"), do: "Amazon S3"
  def name("cloudflare_r2"), do: "Cloudflare R2"
  def name("backblaze_b2"), do: "Backblaze B2"
  def name("hetzner"), do: "Hetzner Object Storage"
  def name("tigris"), do: "Tigris"
  def name("wasabi"), do: "Wasabi"
  def name("digitalocean_spaces"), do: "DigitalOcean Spaces"
  def name("other"), do: gettext("Other S3-compatible (MinIO, Ceph, Garage, …)")

  @doc """
  The `Storage.Bucket` provider a bucket on this service is created as. A
  service the bucket has no provider of its own for is an S3 bucket with an
  endpoint.
  """
  @spec bucket_provider(String.t() | nil) :: String.t()
  def bucket_provider("cloudflare_r2"), do: "r2"
  def bucket_provider("backblaze_b2"), do: "b2"
  def bucket_provider("hetzner"), do: "hetzner"
  def bucket_provider("tigris"), do: "tigris"
  def bucket_provider(_service), do: "s3"

  @doc """
  The service a set of values (typed, or saved) is for: the chosen one, else —
  for a connection saved before the choice existed — the one its endpoint
  belongs to, else nil (a brand-new form, with nothing chosen yet).
  """
  @spec current(values()) :: String.t() | nil
  def current(values) do
    service = text(values["service"])

    cond do
      service in @services -> service
      text(values["endpoint"]) != "" -> infer(text(values["endpoint"]))
      text(values["access_key"]) != "" or text(values["region"]) != "" -> "aws_s3"
      true -> nil
    end
  end

  @doc """
  The name of the service a connection is for (`Tigris`, `Cloudflare R2`, …),
  nil for one with nothing saved yet. For the lists, where the provider's own
  name ("Object Storage (S3-compatible)") is the same for all of them.
  """
  @spec label(values()) :: String.t() | nil
  def label(data) do
    case current(data) do
      nil -> nil
      service -> name(service)
    end
  end

  @doc "The service an endpoint host belongs to (`other` for one nobody knows)."
  @spec infer(String.t()) :: String.t()
  def infer(endpoint) do
    host = endpoint_host(endpoint)

    cond do
      domain?(host, "amazonaws.com") or domain?(host, "amazonaws.com.cn") -> "aws_s3"
      domain?(host, "r2.cloudflarestorage.com") -> "cloudflare_r2"
      domain?(host, "backblazeb2.com") -> "backblaze_b2"
      domain?(host, "your-objectstorage.com") -> "hetzner"
      domain?(host, "tigris.dev") or host == "t3.storage.dev" -> "tigris"
      domain?(host, "wasabisys.com") -> "wasabi"
      domain?(host, "digitaloceanspaces.com") -> "digitalocean_spaces"
      true -> "other"
    end
  end

  defp endpoint_host(endpoint) do
    case Endpoint.parse(endpoint) do
      %{host: host} -> String.downcase(host)
      _ -> ""
    end
  end

  defp domain?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  # ---------------------------------------------------------------------------
  # The form
  # ---------------------------------------------------------------------------

  @doc """
  The fields to show for the values typed so far. The first is always the
  service; the forms send their full values on change, and the rest follow
  from it.
  """
  @spec fields(values()) :: [map()]
  def fields(values) do
    service = current(values)

    [service_field() | fields_for(service)]
  end

  defp service_field do
    options =
      Enum.map(@services, &%{value: &1, label: name(&1)})

    %{
      key: "service",
      label: gettext("Service"),
      type: :select,
      required: true,
      placeholder: nil,
      help: nil,
      prompt: gettext("Choose a service…"),
      options: options
    }
  end

  defp fields_for(nil), do: []

  defp fields_for("aws_s3") do
    [
      region_select(
        gettext("Region"),
        gettext("Where the bucket lives — shown on the bucket's page in the S3 console."),
        aws_groups()
      ),
      key_field(
        "access_key",
        gettext("Access Key ID"),
        "AKIA…",
        gettext("From IAM → Users → Security credentials → Create access key.")
      ),
      secret_field(gettext("Secret Access Key"), nil)
    ]
  end

  defp fields_for("cloudflare_r2") do
    [
      %{
        key: "account_id",
        label: gettext("Account ID"),
        type: :text,
        required: true,
        placeholder: "0123456789abcdef0123456789abcdef",
        help:
          gettext(
            "Cloudflare dashboard → R2 → Account ID. Pasting the whole endpoint works too; it is read for you."
          ),
        options: nil
      },
      %{
        key: "jurisdiction",
        label: gettext("Jurisdiction"),
        type: :select,
        required: false,
        placeholder: nil,
        help: gettext("Only if the bucket was created with one."),
        options: [
          %{value: "", label: gettext("None (default)")},
          %{value: "eu", label: gettext("European Union (EU)")},
          %{value: "fedramp", label: "FedRAMP"}
        ]
      },
      key_field(
        "access_key",
        gettext("Access Key ID"),
        nil,
        gettext("From R2 → Manage R2 API Tokens → Create API token.")
      ),
      secret_field(gettext("Secret Access Key"), nil)
    ]
  end

  defp fields_for("backblaze_b2") do
    [
      region_combo(
        gettext("Region"),
        gettext(
          "The middle of your bucket's endpoint: s3.<region>.backblazeb2.com. Pick one or type it."
        ),
        "us-west-004",
        backblaze_options()
      ),
      key_field(
        "access_key",
        gettext("Application Key ID"),
        nil,
        gettext("From Backblaze → App Keys → Add a New Application Key.")
      ),
      secret_field(gettext("Application Key"), gettext("Shown once, when the key is created."))
    ]
  end

  defp fields_for("hetzner") do
    [
      region_combo(
        gettext("Location"),
        gettext(
          "The bucket's location; its endpoint is <location>.your-objectstorage.com. Pick one or type it."
        ),
        "fsn1",
        Enum.map(@hetzner_locations, fn {code, place} -> %{value: code, label: place} end)
      ),
      key_field(
        "access_key",
        gettext("Access Key"),
        nil,
        gettext("From Hetzner Console → your project → Security → S3 Credentials.")
      ),
      secret_field(gettext("Secret Key"), gettext("Shown once, when the key is created."))
    ]
  end

  defp fields_for("tigris") do
    [
      key_field(
        "access_key",
        gettext("Access Key ID"),
        "tid_…",
        gettext("From console.tigris.dev → Access Keys. The endpoint is t3.storage.dev.")
      ),
      secret_field(gettext("Secret Access Key"), nil)
    ]
  end

  defp fields_for("wasabi") do
    [
      region_combo(
        gettext("Region"),
        gettext("Wasabi's endpoint is s3.<region>.wasabisys.com. Pick one or type it."),
        "eu-central-1",
        Enum.map(@wasabi_regions, fn {code, place} -> %{value: code, label: place} end)
      ),
      key_field("access_key", gettext("Access Key"), nil, nil),
      secret_field(gettext("Secret Key"), nil)
    ]
  end

  defp fields_for("digitalocean_spaces") do
    [
      region_combo(
        gettext("Region"),
        gettext("The Space's datacenter; its endpoint is <region>.digitaloceanspaces.com."),
        "fra1",
        Enum.map(@spaces_regions, fn {code, place} -> %{value: code, label: place} end)
      ),
      key_field(
        "access_key",
        gettext("Spaces Access Key"),
        nil,
        gettext("From API → Spaces Keys → Generate New Key.")
      ),
      secret_field(gettext("Spaces Secret Key"), nil)
    ]
  end

  defp fields_for("other") do
    [
      %{
        key: "endpoint",
        label: gettext("Endpoint"),
        type: :text,
        required: true,
        placeholder: "minio.example.com:9000",
        help:
          gettext(
            "A host, host:port or https:// address, without a path. http:// is only accepted for a site-wide connection."
          ),
        options: nil
      },
      %{
        key: "region",
        label: gettext("Region"),
        type: :text,
        required: false,
        placeholder: "us-east-1",
        help:
          gettext(
            "Leave blank unless the service asks for one — most self-hosted ones accept any."
          ),
        options: nil
      },
      key_field("access_key", gettext("Access Key ID"), nil, nil),
      secret_field(gettext("Secret Access Key"), nil)
    ]
  end

  defp key_field(key, label, placeholder, help) do
    %{
      key: key,
      label: label,
      type: :text,
      required: true,
      placeholder: placeholder,
      help: help,
      options: nil
    }
  end

  defp secret_field(label, help) do
    %{
      key: "secret_key",
      label: label,
      type: :password,
      required: true,
      placeholder: "...",
      help: help,
      options: nil
    }
  end

  # A closed list: Amazon's regions are all in the library, and a typo here
  # would only surface as a failed connection test.
  defp region_select(label, help, groups) do
    %{
      key: "region",
      label: label,
      type: :select,
      required: true,
      placeholder: nil,
      help: help,
      prompt: gettext("Choose a region…"),
      options: nil,
      groups: groups
    }
  end

  # A free-text field with suggestions: the list can be out of date, the
  # service's own console is the authority.
  defp region_combo(label, help, placeholder, options) do
    %{
      key: "region",
      label: label,
      type: :combo,
      required: true,
      placeholder: placeholder,
      help: help,
      options: options
    }
  end

  defp aws_groups do
    Enum.map(AwsRegions.group_by_continent(), fn {continent, regions} ->
      {continent, Enum.map(regions, &%{value: &1.code, label: "#{&1.name} — #{&1.code}"})}
    end)
  end

  defp backblaze_options do
    Enum.map(BackblazeRegions.list(), &%{value: &1.code, label: &1.name})
  end

  # ---------------------------------------------------------------------------
  # What a submit stores
  # ---------------------------------------------------------------------------

  @doc """
  The keys to store for a submitted form: the service and what it asked, with
  `region` and `endpoint` worked out. Every service-specific key is present
  (blank when the service does not use it), so switching a connection's service
  leaves nothing of the old one behind. A blank secret is left out, which means
  "keep the one already saved".
  """
  @spec attrs(values()) :: %{String.t() => String.t()}
  def attrs(params) do
    service = current(params)

    base = %{
      "service" => service || "",
      "access_key" => text(params["access_key"])
    }

    base =
      case text(params["secret_key"]) do
        "" -> base
        secret -> Map.put(base, "secret_key", secret)
      end

    blanks = Map.new(@service_keys, &{&1, ""})
    Map.merge(base, Map.merge(blanks, derive(service, params)))
  end

  # `region` and `endpoint` for what was asked, plus what the form remembers.
  defp derive("aws_s3", params), do: %{"region" => text(params["region"])}

  defp derive("cloudflare_r2", params) do
    account = account_id(params["account_id"])

    jurisdiction =
      if text(params["jurisdiction"]) in ["eu", "fedramp"],
        do: text(params["jurisdiction"]),
        else: ""

    infix = if jurisdiction == "", do: "", else: jurisdiction <> "."

    %{
      "account_id" => account,
      "jurisdiction" => jurisdiction,
      "endpoint" => if(account == "", do: "", else: "#{account}.#{infix}r2.cloudflarestorage.com")
    }
  end

  defp derive("backblaze_b2", params), do: regional(params, &"s3.#{&1}.backblazeb2.com")
  defp derive("hetzner", params), do: regional(params, &"#{&1}.your-objectstorage.com")
  defp derive("wasabi", params), do: regional(params, &"s3.#{&1}.wasabisys.com")

  defp derive("digitalocean_spaces", params),
    do: regional(params, &"#{&1}.digitaloceanspaces.com")

  defp derive("tigris", _params), do: %{"endpoint" => "t3.storage.dev"}

  defp derive("other", params) do
    %{"region" => text(params["region"]), "endpoint" => text(params["endpoint"])}
  end

  # Nothing chosen (a headless save, a test with the form's own keys): keep
  # whatever region and endpoint came.
  defp derive(nil, params) do
    %{"region" => text(params["region"]), "endpoint" => text(params["endpoint"])}
  end

  defp regional(params, host) do
    region = params["region"] |> text() |> String.downcase()

    endpoint =
      if Regex.match?(@region_format, region), do: host.(region), else: ""

    %{"region" => region, "endpoint" => endpoint}
  end

  # An account id, or the one in a pasted endpoint (`<id>.r2.cloudflarestorage.com`,
  # `https://<id>.eu.r2…/`): the first label of the host.
  defp account_id(value) do
    value
    |> text()
    |> String.replace(~r{\A[a-zA-Z][a-zA-Z0-9+.-]*://}, "")
    |> String.split(["/", "."], parts: 2)
    |> hd()
    |> String.downcase()
  end

  # ---------------------------------------------------------------------------
  # Re-rendering
  # ---------------------------------------------------------------------------

  @doc """
  The typed values once `incoming` (the form as it was just sent) arrives over
  `previous`. Changing the service drops what the old one asked — a region of
  one provider is not a region of the next — and keeps the keys, which are the
  same shape everywhere. Decided by comparing the service, not by which input
  fired, so it holds however the change event was made.
  """
  @spec changed(values(), values()) :: values()
  def changed(previous, incoming) do
    merged = Map.merge(previous, incoming)

    if text(previous["service"]) != text(incoming["service"]),
      do: Map.drop(merged, @service_keys),
      else: merged
  end

  @doc """
  The saved values the form may show next to the typed ones. A connection being
  switched to another service shows none of the old service's region, endpoint
  or account (they would be rendered as if they belonged to the new one).
  """
  @spec saved(values(), values()) :: values()
  def saved(data, typed) do
    chosen = text(typed["service"])
    current = current(data)
    data = recover_endpoint_fields(data, current)

    data =
      if chosen != "" and chosen != current,
        do: Map.drop(data, @service_keys),
        else: data

    # A connection saved before the choice existed shows the service its
    # endpoint belongs to.
    if current && text(data["service"]) == "",
      do: Map.put(data, "service", current),
      else: data
  end

  # Older connections stored only the endpoint. Recover the fields the new
  # service form asks for before it rebuilds that endpoint on save.
  defp recover_endpoint_fields(data, service) do
    host = endpoint_host(data["endpoint"])

    inferred =
      case service do
        "cloudflare_r2" ->
          case Regex.run(~r/\A([^.]+)\.(?:(eu|fedramp)\.)?r2\.cloudflarestorage\.com\z/, host) do
            [_, account, jurisdiction] ->
              %{"account_id" => account, "jurisdiction" => jurisdiction}

            [_, account] ->
              %{"account_id" => account, "jurisdiction" => ""}

            _ ->
              %{}
          end

        service when service in ["backblaze_b2", "hetzner", "wasabi", "digitalocean_spaces"] ->
          regional_endpoint_region(host)

        _ ->
          %{}
      end

    Enum.reduce(inferred, data, fn {key, value}, acc ->
      if text(acc[key]) == "", do: Map.put(acc, key, value), else: acc
    end)
  end

  # The region in a regional endpoint host, as `derive/2` builds them.
  defp regional_endpoint_region(host) do
    case String.split(host, ".") do
      ["s3", region, "backblazeb2", "com"] -> %{"region" => region}
      [region, "your-objectstorage", "com"] -> %{"region" => region}
      ["s3", region, "wasabisys", "com"] -> %{"region" => region}
      [region, "digitaloceanspaces", "com"] -> %{"region" => region}
      _ -> %{}
    end
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.trim()
end
