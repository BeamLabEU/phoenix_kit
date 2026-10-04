defmodule PhoenixKit.Test.ModuleGettext do
  @moduledoc """
  A feature module's own Gettext backend, as `PhoenixKitBilling.Gettext` is:
  a plain `use Gettext.Backend` with base-code catalogues (`en`, `es`, `pt`)
  and no locale of its own on the process. Used to check that a message
  rendered for a recipient reaches module backends in the recipient's language,
  not only `PhoenixKitWeb.Gettext`.
  """
  use Gettext.Backend,
    otp_app: :phoenix_kit,
    priv: "test/support/module_gettext_fixtures"
end
