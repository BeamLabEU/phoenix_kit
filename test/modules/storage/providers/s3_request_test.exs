defmodule PhoenixKit.Modules.Storage.Providers.S3RequestTest do
  @moduledoc """
  ExAws looks a host up from the region before the caller's `:host` applies,
  and raises for a region shaped like AWS's that AWS lacks (Backblaze B2's).
  `S3Request.config/1` must build such a config, signed for the real region.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Providers.S3Request

  @b2 [
    access_key_id: "key",
    secret_access_key: "secret",
    region: "us-west-002",
    host: "s3.us-west-002.backblazeb2.com",
    scheme: "https://",
    port: 443
  ]

  test "ExAws alone cannot build a config for a B2 region" do
    assert_raise RuntimeError, ~r/not supported in region us-west-002/, fn ->
      ExAws.Config.new(:s3, @b2)
    end
  end

  test "a named host keeps its host and the region it is signed for" do
    for region <- ~w(us-west-002 eu-central-003 us-east-005 hel1) do
      config = S3Request.config(Keyword.put(@b2, :region, region))
      assert config.region == region
      assert config.host == "s3.us-west-002.backblazeb2.com"
      assert config.scheme == "https://"
    end
  end

  test "a presigned URL for B2 is signed for the B2 region" do
    {:ok, url} =
      @b2
      |> S3Request.config()
      |> ExAws.S3.presigned_url(:get, "bucket", "a/b.jpg", expires_in: 60)

    assert url =~ "https://s3.us-west-002.backblazeb2.com/bucket/a/b.jpg?"
    assert url =~ "%2Fus-west-002%2Fs3%2Faws4_request"
  end

  test "without a host, the config is ExAws's own (AWS itself)" do
    config = S3Request.config(region: "eu-central-1", access_key_id: "k", secret_access_key: "s")
    assert config.region == "eu-central-1"
    assert config.host == "s3.eu-central-1.amazonaws.com"
  end
end
