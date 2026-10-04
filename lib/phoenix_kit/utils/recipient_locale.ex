defmodule PhoenixKit.Utils.RecipientLocale do
  @moduledoc """
  Resolves which locale a message should be rendered in for a given recipient.

  Outbound messages (email, and the external notification channels) render on
  a background or request process that has no meaningful Gettext locale of its
  own — the sender's locale is not the recipient's. This module is the single
  answer to "whose language is this message in".

  ## Where the preference lives

  A user's dialect preference is stored full ("en-GB", "pt-BR") in
  `custom_fields["preferred_locale"]`, written by
  `PhoenixKit.Users.Auth.update_user_locale_preference/2` from the language
  switcher. Absent means the user never chose one.

  ## Two consumers, two shapes

  - `for_rendering/1` — for **template lookup**. Returns the full dialect and
    never `nil`, falling back to the site's content language and then `"en"`.
    Template resolution does its own dialect→base narrowing ("en-GB" is tried
    before "en"), so handing it the dialect strictly beats pre-truncating.
  - `base/1` — for **Gettext**, which keys on base codes and treats `nil` as
    "leave the current locale alone".

  ## Installing it

  `in_locale/2` runs a function with a locale installed on the process, which is
  how a Gettext-backed default reaches the right language: these render on a
  background worker or on behalf of another user, so the locale arrives as a
  value rather than being ambient. `nil` means "leave the current locale alone"
  — what a screen rendering for its own viewer wants. It installs the locale
  for the core backend and for every feature module's backend alike, as the
  web does (`PhoenixKitWeb.Users.Auth.put_gettext_locale/2`).

  ## Failure

  `for_rendering/1` is total. The site default is read through
  `PhoenixKit.Settings`, which can raise on an unowned checkout *or exit* on a
  dead pool; both are caught and answered with `"en"`. An unreachable database
  must degrade a message to English, never fail the send — this is the path
  `PhoenixKit.Users.LoginAlerts` calls during sign-in.
  """

  alias PhoenixKit.Settings

  @fallback "en"

  @doc """
  The recipient's stored dialect preference, or `nil` when they have none.

  Accepts anything: a `%User{}`, a plain map, or a bare email string (used by
  the magic-link registration path, where no account exists yet).

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.preferred(%{custom_fields: %{"preferred_locale" => "en-GB"}})
      "en-GB"
      iex> RecipientLocale.preferred("someone@example.com")
      nil
  """
  @spec preferred(term()) :: String.t() | nil
  def preferred(%{custom_fields: fields}) when is_map(fields) do
    case Map.get(fields, "preferred_locale") do
      locale when is_binary(locale) and locale != "" -> locale
      _ -> nil
    end
  end

  def preferred(_recipient), do: nil

  @doc """
  The recipient's preference as a base language code, or `nil`.

  For Gettext, which keys on base codes; `nil` means "no preference, leave the
  current locale alone".

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.base(%{custom_fields: %{"preferred_locale" => "pt-BR"}})
      "pt"
  """
  @spec base(term()) :: String.t() | nil
  def base(recipient) do
    with locale when is_binary(locale) <- preferred(recipient) do
      locale |> String.split("-") |> hd()
    end
  end

  @doc """
  The locale to render a template in for `recipient`. Never `nil`.

  Preference → the site's content language → `"en"`.

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.for_rendering(%{custom_fields: %{"preferred_locale" => "uk"}})
      "uk"
  """
  @spec for_rendering(term()) :: String.t()
  def for_rendering(recipient) do
    preferred(recipient) || site_default()
  end

  @doc """
  Runs `fun` with `locale` installed on the process, restoring it afterwards.

  A `nil` locale runs `fun` untouched, so a caller with no recipient preference
  keeps whatever locale is already in force.

  Two locales are installed, both restored afterwards (also when `fun` raises):

  - `PhoenixKitWeb.Gettext` gets `gettext_locale/1`, so a dialect the core
    catalogue does not have reads its base language's translation.
  - The process-global Gettext locale gets the **base** language (`"es"` for
    `"es-ES"`). This is the one a feature module's own backend reads
    (`PhoenixKitBilling.Gettext` in a billing default, any backend called while
    `PhoenixKit.Email.Content` resolves a default or a notification renders):
    a backend with no locale of its own falls back to the global one. Without
    it a module's text came out in the *sender's* language — the global locale
    of the worker or of the admin's LiveView — not the recipient's.

  The global value is the base code because that is how module catalogues are
  named (`es`, `et`, `ru`), and Gettext matches a locale exactly: `"es-ES"` or
  `"es_ES"` would match none of them. A module that ships a dialect catalogue
  (`pt_BR`) is read in its base language here; its backend, unlike the core
  one, is not known to this module.

  A backend that already has a locale of its own on this process
  (`Gettext.put_locale(backend, _)`) keeps it — that is an explicit choice
  this function does not override.

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.in_locale(nil, fn -> :ran end)
      :ran
      iex> RecipientLocale.in_locale("es-ES", fn -> Gettext.get_locale(PhoenixKitWeb.Gettext) end)
      "es"
      iex> RecipientLocale.in_locale("es-ES", fn -> Gettext.get_locale() end)
      "es"
  """
  @spec in_locale(String.t() | nil, (-> result)) :: result when result: term()
  def in_locale(nil, fun), do: fun.()

  def in_locale(locale, fun) when is_binary(locale) do
    Gettext.with_locale(base_locale(locale), fn ->
      Gettext.with_locale(PhoenixKitWeb.Gettext, gettext_locale(locale), fun)
    end)
  end

  @doc """
  The `PhoenixKitWeb.Gettext` locale that translates `locale`.

  Preferences and Languages codes are dialects (`"es-ES"`, `"pt-BR"`), but the
  backend looks a locale up exactly and its catalogues are named for base
  languages (`es`), or, following Gettext's convention, `pt_BR` for a dialect.
  So: `locale` itself when the catalogue has it, else its Gettext spelling
  (`pt-BR` → `pt_BR`), else its base language — split on `-` or `_`. Installing
  `"es-ES"` as it was matched no catalogue, and every default came out in
  English.

  Shared by the web (`PhoenixKitWeb.Users.Auth.put_gettext_locale/2`) and by
  `in_locale/2`, so the two cannot pick different translations for one
  language. (`base/1` still hands `in_locale/2` a pre-truncated base code, so
  the notification workers read the base catalogue even where a dialect one
  exists; core ships none.)

      iex> PhoenixKit.Utils.RecipientLocale.gettext_locale("es-ES")
      "es"
      iex> PhoenixKit.Utils.RecipientLocale.gettext_locale("ru")
      "ru"
  """
  @spec gettext_locale(String.t()) :: String.t()
  def gettext_locale(locale) when is_binary(locale),
    do: gettext_locale(locale, Gettext.known_locales(PhoenixKitWeb.Gettext))

  # The choice against an explicit list of `known` locales — public only so the
  # dialect-catalogue branches can be tested without shipping such a catalogue.
  @doc false
  @spec gettext_locale(String.t(), [String.t()]) :: String.t()
  def gettext_locale(locale, known) do
    case String.split(locale, ["-", "_"]) do
      ["" | _] ->
        @fallback

      [base | rest] ->
        base = String.downcase(base)
        candidates = [locale, Enum.join([base | upcase_region(rest)], "_")]
        Enum.find(candidates, base, &(&1 in known))
    end
  end

  # The base language of `locale`, as module catalogues name it: `es` for
  # "es-ES", "ES_es" or "es". The fallback for an empty one, like
  # `gettext_locale/2`.
  defp base_locale(locale) do
    case locale |> String.split(["-", "_"]) |> hd() do
      "" -> @fallback
      base -> String.downcase(base)
    end
  end

  # Gettext names a dialect catalogue `pt_BR`: the region upper-case.
  defp upcase_region([region | rest]), do: [String.upcase(region) | rest]
  defp upcase_region([]), do: []

  defp site_default do
    case Settings.get_content_language() do
      language when is_binary(language) and language != "" -> language
      _ -> @fallback
    end
  rescue
    _ -> @fallback
  catch
    :exit, _ -> @fallback
  end
end
