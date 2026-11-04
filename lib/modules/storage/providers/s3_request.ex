defmodule PhoenixKit.Modules.Storage.Providers.S3Request do
  @moduledoc """
  ExAws for S3-compatible services, for callers that name the host.

  `ExAws.request/2` builds its config with `ExAws.Config.new/2`, which looks a
  host up from the region **before** the caller's `:host` is applied, and
  raises when the region looks like an AWS one that AWS does not have:
  Backblaze B2's `us-west-002` or `eu-central-003` match AWS's region pattern,
  so every B2 request failed with "s3 not supported in region us-west-002 for
  partition aws", the explicit B2 host notwithstanding (ExAws 2.7).

  When the options name a `:host`, `config/1` builds the config with a region
  ExAws knows and then puts the real one back: it is the region requests are
  signed for, which S3-compatible services check. Without a `:host` (AWS
  itself), the config is ExAws's own.
  """

  # Any region ExAws resolves; only used to build the defaults the caller's
  # host and region then replace.
  @neutral_region "us-east-1"

  @doc "The ExAws config for `opts` (see the moduledoc)."
  @spec config(keyword()) :: map()
  def config(opts) do
    if Keyword.get(opts, :host) do
      region = Keyword.get(opts, :region) || @neutral_region

      :s3
      |> ExAws.Config.new(Keyword.put(opts, :region, @neutral_region))
      |> Map.put(:region, region)
    else
      ExAws.Config.new(:s3, opts)
    end
  end

  @doc "`ExAws.request/2`, with the config from `config/1`."
  @spec request(ExAws.Operation.t(), keyword()) :: term()
  def request(operation, opts), do: ExAws.Operation.perform(operation, config(opts))
end
