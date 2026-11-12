defmodule PhoenixKit.Modules.Storage.ManagerBucketAccessTest do
  @moduledoc """
  How a remote bucket that holds a file serves it. A public bucket's plain
  object URL answers with the object's stored headers, so a file the app
  would never show in place is handed out as a signed URL that overrides
  them — or proxied when the provider cannot sign one. Never the plain URL.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Manager

  defmodule Signing do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"

    def signed_download_url(_bucket, key, opts),
      do: {:ok, "https://signed/#{key}?#{opts[:disposition]}"}
  end

  defmodule FailingSigner do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"
    def signed_download_url(_bucket, _key, _opts), do: {:error, :no_credentials}
  end

  defmodule NoSigning do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"
  end

  @download [disposition: "attachment; filename=\"a.zip\"", content_type: "application/zip"]

  test "an inline file on a public bucket gets the plain object URL" do
    assert Manager.bucket_access(%{access_type: "public"}, "k", Signing, nil) ==
             {:redirect, "https://cdn.example.com/k"}
  end

  test "a download on a public bucket gets a signed URL carrying the disposition" do
    assert {:signed_redirect, url} =
             Manager.bucket_access(%{access_type: "public"}, "k", Signing, @download)

    assert url =~ "attachment"
  end

  test "a download is proxied when the provider cannot sign, never given the plain URL" do
    for provider <- [FailingSigner, NoSigning] do
      assert Manager.bucket_access(%{access_type: "public"}, "k", provider, @download) ==
               {:proxy, "k"},
             inspect(provider)
    end
  end

  test "a private bucket is always proxied" do
    for download <- [nil, @download] do
      assert Manager.bucket_access(%{access_type: "private"}, "k", Signing, download) ==
               {:proxy, "k"}
    end
  end

  defmodule ExpiryRecorder do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"

    def signed_download_url(_bucket, key, opts),
      do: {:ok, "https://signed/#{key}?expires=#{opts[:expires_in]}"}
  end

  defmodule NoPublicUrl do
    def public_url(_bucket, _key), do: nil
  end

  test "a public bucket with no public URL for the object is proxied, not skipped" do
    assert Manager.bucket_access(%{access_type: "public"}, "k", NoPublicUrl, nil) == {:proxy, "k"}
  end

  test "a signed bucket is served by a short presigned URL, never the plain one" do
    for download <- [nil, @download] do
      assert {:signed_redirect, "https://signed/k" <> _} =
               Manager.bucket_access(%{access_type: "signed"}, "k", Signing, download)

      assert {:signed_redirect, "https://signed/k?expires=300"} =
               Manager.bucket_access(%{access_type: "signed"}, "k", ExpiryRecorder, download)
    end

    for provider <- [FailingSigner, NoSigning] do
      assert Manager.bucket_access(%{access_type: "signed"}, "k", provider, nil) == {:proxy, "k"}
    end
  end

  test "a signed bucket's URL lives as long as asked (a video's), else 300 seconds" do
    assert {:signed_redirect, "https://signed/k?expires=14400"} =
             Manager.bucket_access(%{access_type: "signed"}, "k", ExpiryRecorder, nil, 14_400)

    assert {:signed_redirect, "https://signed/k?expires=300"} =
             Manager.bucket_access(%{access_type: "signed"}, "k", ExpiryRecorder, nil)
  end
end
