defmodule PhoenixKitWeb.LegalGettextManifest do
  @moduledoc false

  # Lists every translatable string used by `phoenix_kit_legal` so that
  # `mix gettext.extract` records them into PhoenixKit core's POT, where
  # Legal translations live.
  #
  # `phoenix_kit_legal` uses `PhoenixKitWeb.Gettext` as its only Gettext
  # backend (architectural decision — Legal does not own a backend), but
  # the extractor doesn't walk into deps. This manifest re-emits those
  # gettext calls from core's own source so the strings end up in
  # `priv/gettext/default.pot` and can be translated in every locale.
  #
  # When `phoenix_kit_legal` adds or renames a translatable string, refresh
  # this list. From the `phoenix_kit_legal` checkout:
  #
  #     grep -hEo 'gettext\("[^"]+"\)' \
  #       lib/phoenix_kit_legal/legal.ex \
  #       lib/phoenix_kit_legal/web/cookie_consent.ex \
  #       lib/phoenix_kit_legal/web/settings.ex \
  #       lib/phoenix_kit_legal/web/settings.html.heex \
  #     | sort -u
  #
  # This module is never called at runtime — it exists purely as an
  # extraction target for `mix gettext.extract`.

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc false
  def __extract__ do
    [
      gettext("Accept All"),
      gettext("Acceptable Use Policy"),
      gettext("Address imported from Organization"),
      gettext("Analytics"),
      gettext("CCPA Notice at Collection"),
      gettext("Close"),
      gettext("Consent widget settings saved"),
      gettext("Cookie Policy"),
      gettext("Cookie consent"),
      gettext("Cookie consent widget disabled"),
      gettext("Cookie consent widget enabled"),
      gettext("Cookie preferences"),
      gettext("Customize"),
      gettext("DPO contact saved"),
      gettext("Data Retention Policy"),
      gettext("Do Not Sell My Personal Information"),
      gettext("Email imported from General Settings"),
      gettext("Essential"),
      gettext("Failed to generate page: %{reason}"),
      gettext("Failed to import address"),
      gettext("Failed to import email"),
      gettext("Failed to publish page: %{reason}"),
      gettext("Failed to save DPO contact"),
      gettext("Failed to save frameworks"),
      gettext("Failed to save settings"),
      gettext("Failed to update setting"),
      gettext("Generated %{count} pages"),
      gettext("Help us understand how you use our site to improve your experience."),
      gettext("Legal"),
      gettext("Legal Settings"),
      gettext("Legal pages reset successfully. You can now regenerate them."),
      gettext("Manage your cookie settings"),
      gettext("Marketing"),
      gettext("No issues detected — reset not needed"),
      gettext("Page generated successfully"),
      gettext("Page published successfully"),
      gettext("Preferences"),
      gettext("Privacy Policy"),
      gettext("Privacy Preferences"),
      gettext("Reject"),
      gettext("Reject All"),
      gettext("Remember your settings like language and region preferences."),
      gettext("Required"),
      gettext("Required for core functionality. These cannot be disabled."),
      gettext("Reset failed: %{reason}"),
      gettext("Save Preferences"),
      gettext("Terms of Service"),
      gettext("Used for personalized advertising and measuring ad effectiveness."),
      gettext("We use cookies to enhance your browsing experience and analyze our traffic."),
      gettext("We value your privacy")
    ]
  end
end
