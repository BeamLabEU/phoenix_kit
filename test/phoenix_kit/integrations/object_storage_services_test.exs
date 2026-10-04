defmodule PhoenixKit.Integrations.ObjectStorageServicesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.ObjectStorageServices, as: Services
  alias PhoenixKit.Integrations.Providers

  defp keys(values), do: values |> Services.fields() |> Enum.map(& &1.key)

  describe "fields/1" do
    test "a new form shows the service choice and nothing else" do
      assert [
               %{key: "service", type: :select, required: true} =
                 field
             ] =
               Services.fields(%{})

      assert Enum.map(field.options, & &1.value) == Services.service_keys()
    end

    test "each service asks for what it needs" do
      assert keys(%{"service" => "aws_s3"}) == ~w(service region access_key secret_key)

      assert keys(%{"service" => "cloudflare_r2"}) ==
               ~w(service account_id jurisdiction access_key secret_key)

      assert keys(%{"service" => "backblaze_b2"}) == ~w(service region access_key secret_key)
      assert keys(%{"service" => "tigris"}) == ~w(service access_key secret_key)
      assert keys(%{"service" => "wasabi"}) == ~w(service region access_key secret_key)

      assert keys(%{"service" => "digitalocean_spaces"}) ==
               ~w(service region access_key secret_key)

      assert keys(%{"service" => "other"}) == ~w(service endpoint region access_key secret_key)
    end

    test "the Amazon region is a grouped list from the regions library" do
      region = Enum.find(Services.fields(%{"service" => "aws_s3"}), &(&1.key == "region"))

      assert region.type == :select
      assert {"Europe", options} = List.keyfind(region.groups, "Europe", 0)
      assert %{value: "eu-central-1"} = Enum.find(options, &(&1.value == "eu-central-1"))
    end

    test "Backblaze, Wasabi and Spaces take a typed region with suggestions" do
      for service <- ~w(backblaze_b2 wasabi digitalocean_spaces) do
        region = Enum.find(Services.fields(%{"service" => service}), &(&1.key == "region"))
        assert region.type == :combo
        assert region.options != []
      end
    end

    test "a connection saved before the choice existed opens on the service its endpoint names" do
      assert Services.current(%{"access_key" => "k"}) == "aws_s3"
      assert Services.current(%{"endpoint" => "s3.us-west-002.backblazeb2.com"}) == "backblaze_b2"

      assert Services.current(%{"endpoint" => "https://a.r2.cloudflarestorage.com"}) ==
               "cloudflare_r2"

      assert Services.current(%{"endpoint" => "fly.storage.tigris.dev"}) == "tigris"
      assert Services.current(%{"endpoint" => "s3.eu-central-1.wasabisys.com"}) == "wasabi"

      assert Services.current(%{"endpoint" => "fra1.digitaloceanspaces.com"}) ==
               "digitalocean_spaces"

      assert Services.current(%{"endpoint" => "minio.local:9000"}) == "other"
      assert Services.current(%{"service" => "wasabi", "endpoint" => "minio.local"}) == "wasabi"
      assert Services.current(%{}) == nil
    end
  end

  describe "attrs/1" do
    test "Amazon stores the region and no endpoint" do
      assert %{"service" => "aws_s3", "region" => "eu-north-1", "endpoint" => ""} =
               Services.attrs(%{
                 "service" => "aws_s3",
                 "region" => "eu-north-1",
                 "access_key" => " AKIA ",
                 "secret_key" => "s"
               })
    end

    test "R2 builds its endpoint from the account id, with a jurisdiction when there is one" do
      assert %{
               "endpoint" => "abc123.r2.cloudflarestorage.com",
               "account_id" => "abc123",
               "region" => ""
             } =
               Services.attrs(%{"service" => "cloudflare_r2", "account_id" => " ABC123 "})

      assert %{"endpoint" => "abc123.eu.r2.cloudflarestorage.com", "jurisdiction" => "eu"} =
               Services.attrs(%{
                 "service" => "cloudflare_r2",
                 "account_id" => "abc123",
                 "jurisdiction" => "eu"
               })

      assert %{"jurisdiction" => ""} =
               Services.attrs(%{
                 "service" => "cloudflare_r2",
                 "account_id" => "abc123",
                 "jurisdiction" => "../evil"
               })
    end

    test "R2 reads the account out of a pasted endpoint" do
      assert %{"account_id" => "abc123", "endpoint" => "abc123.r2.cloudflarestorage.com"} =
               Services.attrs(%{
                 "service" => "cloudflare_r2",
                 "account_id" => "https://abc123.r2.cloudflarestorage.com/"
               })
    end

    test "Backblaze, Wasabi and Spaces build the endpoint from the region" do
      assert %{"endpoint" => "s3.us-west-004.backblazeb2.com", "region" => "us-west-004"} =
               Services.attrs(%{"service" => "backblaze_b2", "region" => "US-West-004"})

      assert %{"endpoint" => "s3.eu-central-1.wasabisys.com"} =
               Services.attrs(%{"service" => "wasabi", "region" => "eu-central-1"})

      assert %{"endpoint" => "fra1.digitaloceanspaces.com"} =
               Services.attrs(%{"service" => "digitalocean_spaces", "region" => "fra1"})
    end

    test "a region that is not a region name never becomes part of a host" do
      assert %{"endpoint" => ""} =
               Services.attrs(%{"service" => "backblaze_b2", "region" => "evil.com/x"})
    end

    test "Tigris has one endpoint and no region" do
      assert %{"endpoint" => "t3.storage.dev", "region" => ""} =
               Services.attrs(%{"service" => "tigris", "region" => "fra"})
    end

    test "Other takes the endpoint as typed" do
      assert %{"endpoint" => "minio.local:9000", "region" => "us-east-1"} =
               Services.attrs(%{
                 "service" => "other",
                 "endpoint" => " minio.local:9000 ",
                 "region" => "us-east-1"
               })
    end

    test "switching service leaves nothing of the old one behind" do
      assert %{"account_id" => "", "jurisdiction" => "", "region" => ""} =
               Services.attrs(%{
                 "service" => "tigris",
                 "account_id" => "abc",
                 "jurisdiction" => "eu",
                 "region" => "eu-west-1"
               })
    end

    test "a blank secret is left out, so the saved one is kept" do
      refute Map.has_key?(
               Services.attrs(%{"service" => "aws_s3", "secret_key" => " "}),
               "secret_key"
             )

      assert %{"secret_key" => "s3cret"} =
               Services.attrs(%{"service" => "aws_s3", "secret_key" => "s3cret"})
    end

    test "no service chosen (a headless save) keeps the region and endpoint that came" do
      assert %{"service" => "", "region" => "eu-central-1", "endpoint" => ""} =
               Services.attrs(%{"region" => "eu-central-1", "access_key" => "k"})
               |> Map.put("service", "")

      # an endpoint with no service is read as the service it belongs to
      assert %{"service" => "other", "endpoint" => "s3.x.example.com"} =
               Services.attrs(%{"endpoint" => "s3.x.example.com"})
    end
  end

  describe "re-rendering" do
    test "changing the service drops what the old one asked and keeps the keys" do
      previous = %{
        "service" => "wasabi",
        "region" => "eu-central-1",
        "access_key" => "k",
        "secret_key" => "s"
      }

      incoming = %{
        "service" => "backblaze_b2",
        "region" => "eu-central-1",
        "access_key" => "k2",
        "secret_key" => "s"
      }

      assert Services.changed(previous, incoming) ==
               %{"service" => "backblaze_b2", "access_key" => "k2", "secret_key" => "s"}

      same = Map.put(incoming, "service", "wasabi")
      assert Services.changed(previous, same) == same
    end

    test "switching an edited connection to another service shows none of its old region" do
      data = %{
        "service" => "wasabi",
        "region" => "eu-central-1",
        "endpoint" => "s3.eu-central-1.wasabisys.com"
      }

      assert %{"service" => "wasabi", "region" => "eu-central-1"} = Services.saved(data, %{})
      saved = Services.saved(data, %{"service" => "backblaze_b2"})
      refute Map.has_key?(saved, "region")
      refute Map.has_key?(saved, "endpoint")
    end

    test "legacy R2 endpoints recover the account and jurisdiction for an unchanged save" do
      for jurisdiction <- ["", "eu", "fedramp"] do
        infix = if jurisdiction == "", do: "", else: jurisdiction <> "."
        endpoint = "acct.#{infix}r2.cloudflarestorage.com"
        data = %{"endpoint" => endpoint, "access_key" => "k", "secret_key" => "s"}
        saved = Services.saved(data, %{})

        assert saved["account_id"] == "acct"
        assert saved["jurisdiction"] == jurisdiction
        assert Services.attrs(saved)["endpoint"] == endpoint
      end
    end

    test "legacy regional endpoints supply a region when none was stored" do
      for {service, endpoint, region} <- [
            {"backblaze_b2", "s3.us-west-004.backblazeb2.com", "us-west-004"},
            {"wasabi", "s3.eu-central-1.wasabisys.com", "eu-central-1"},
            {"digitalocean_spaces", "fra1.digitaloceanspaces.com", "fra1"}
          ] do
        saved = Services.saved(%{"endpoint" => endpoint}, %{})
        assert saved["region"] == region
        assert saved["service"] == service
        assert Services.attrs(saved)["endpoint"] == endpoint
      end
    end

    test "service inference matches the endpoint host rather than a substring" do
      for endpoint <- [
            "amazonaws.com.example.org",
            "minio.wasabisys.com.example.org",
            "minio.local:9000/?host=backblazeb2.com"
          ] do
        assert Services.infer(endpoint) == "other"
      end
    end

    test "a legacy connection is shown as the service its endpoint names" do
      assert %{"service" => "backblaze_b2"} =
               Services.saved(%{"endpoint" => "s3.us-west-002.backblazeb2.com"}, %{})
    end
  end

  describe "label/1" do
    test "the list's service label works before a form loads the setup module" do
      code = """
      alias PhoenixKit.Integrations.ObjectStorageServices, as: Services
      alias PhoenixKit.Integrations.Providers
      false = :code.is_loaded(Services)
      "Tigris" = Providers.setup_label(%{setup_module: Services}, %{"service" => "tigris"})
      """

      beam_dir = Providers |> :code.which() |> List.to_string() |> Path.dirname()

      assert {_output, 0} =
               System.cmd("elixir", ["-pa", beam_dir, "-e", code],
                 stderr_to_stdout: true,
                 env: [{"ERL_FLAGS", "+S 2:2"}]
               )
    end

    test "names the service of a connection, inferring it for an old one" do
      assert Services.label(%{"service" => "tigris"}) == "Tigris"
      assert Services.label(%{"endpoint" => "s3.us-west-002.backblazeb2.com"}) == "Backblaze B2"
      assert Services.label(%{}) == nil

      assert Providers.setup_label(Providers.get("object_storage"), %{"service" => "wasabi"}) ==
               "Wasabi"

      assert Providers.setup_label(Providers.get("smtp"), %{"host" => "h"}) == nil
    end
  end

  describe "the provider" do
    test "still declares the four keys a connection is read by, with only the keys required" do
      provider = Providers.get("object_storage")

      for key <- ~w(access_key secret_key region endpoint service account_id jurisdiction),
          do: assert(Enum.any?(provider.setup_fields, &(&1.key == key)), key)

      assert provider.setup_fields |> Enum.filter(& &1.required) |> Enum.map(& &1.key) ==
               ~w(access_key secret_key)

      assert Providers.dynamic_setup?(provider)
    end

    test "bucket providers follow the service" do
      assert Services.bucket_provider("cloudflare_r2") == "r2"
      assert Services.bucket_provider("backblaze_b2") == "b2"
      assert Services.bucket_provider("tigris") == "tigris"
      assert Services.bucket_provider("aws_s3") == "s3"
      assert Services.bucket_provider("wasabi") == "s3"
      assert Services.bucket_provider(nil) == "s3"
    end

    test "other providers keep their declared fields and the old save rule" do
      smtp = Providers.get("smtp")
      refute Providers.dynamic_setup?(smtp)
      assert Providers.setup_fields(smtp) == smtp.setup_fields
      assert Providers.setup_attrs(smtp, %{"host" => " h ", "password" => ""})["host"] == "h"
      refute Map.has_key?(Providers.setup_attrs(smtp, %{"password" => ""}), "password")
    end
  end
end
