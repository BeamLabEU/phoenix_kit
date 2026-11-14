defmodule PhoenixKit.Users.EmailDomain do
  @moduledoc """
  Two checks of an address typed into a public sign-up form, both about its
  domain and neither about whether an account exists:

    * `check/1` asks DNS whether the domain can receive mail at all, so a
      sign-up for `someone@no-such-domain.example` is refused before a mail is
      sent that can only bounce;
    * `suggestion/1` spots the common typos of the big providers
      (`gmial.com`, `hotmail.con`) and offers the corrected address. It is a
      hint: nothing is refused for it and DNS is not asked.

  On by default; the switch is on Settings → Authorization → Abuse protection
  (`email_domain_check_enabled`). `config :phoenix_kit, :email_domain_check,
  false` switches both off whatever the setting says: for a test environment,
  where sign-ups use addresses like `user@example.com` (a domain that really
  does publish "no mail here") and DNS may not be reachable.

  ## Only a definite answer refuses

  `check/1` refuses when DNS says the domain does not exist, when it has
  neither a mail host (MX) nor an address (A/AAAA: the fallback mail servers
  use), or when it publishes a null MX (RFC 7505, "this domain takes no
  mail"). A timeout, a resolver error or anything else unreadable passes: a
  DNS hiccup must not close sign-up. Non-ASCII and address-literal domains are
  not looked up.

  Call it on a submit only, after the bot check and the rate limiter, so the
  form cannot be used to make the server do lookups for free
  (`Auth.register_user/3` with `check_email_domain: true` and
  `MagicLinkRegistration.send_registration_link/3` do).
  """

  alias PhoenixKit.Settings

  @setting "email_domain_check_enabled"
  @timeout 2_000

  # Providers people actually mistype. A domain on this list is never
  # "corrected" to another one on it (mail.com is not a typo of gmail.com).
  @known_domains ~w(
    gmail.com googlemail.com
    yahoo.com ymail.com rocketmail.com yahoo.co.uk yahoo.fr yahoo.de yahoo.es yahoo.it
    hotmail.com hotmail.co.uk hotmail.fr hotmail.de hotmail.it hotmail.es
    outlook.com outlook.fr outlook.de live.com live.co.uk msn.com
    icloud.com me.com mac.com
    aol.com proton.me protonmail.com pm.me
    gmx.com gmx.net gmx.de web.de t-online.de freenet.de
    mail.com email.com fastmail.com zoho.com hey.com
    mail.ru yandex.ru yandex.com ya.ru rambler.ru bk.ru list.ru inbox.ru
    ukr.net i.ua meta.ua
    wp.pl o2.pl interia.pl onet.pl
    orange.fr free.fr laposte.net sfr.fr wanadoo.fr
    libero.it virgilio.it tiscali.it
    qq.com 163.com 126.com sina.com
    comcast.net verizon.net att.net sbcglobal.net btinternet.com
  )

  # A mistyped ending, on any domain.
  @tld_typos %{
    "con" => "com",
    "cmo" => "com",
    "ocm" => "com",
    "vom" => "com",
    "xom" => "com",
    "cim" => "com",
    "comm" => "com",
    "coom" => "com",
    "nte" => "net",
    "ner" => "net",
    "nett" => "net",
    "ogr" => "org",
    "orgg" => "org"
  }

  @doc "The setting key of the switch."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc "Whether the checks run (the setting, default on, and the config override)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:phoenix_kit, :email_domain_check, true) != false and
      Settings.get_boolean_setting(@setting, true)
  end

  @doc """
  Whether the address's domain can receive mail. `:ok` while the check is off,
  for a domain that can, and whenever DNS gave no definite answer.
  """
  @spec check(term()) :: :ok | {:error, :no_mail_host}
  def check(email) do
    with true <- enabled?(),
         {:ok, domain} <- lookup_domain(email) do
      mail_host(domain)
    else
      _ -> :ok
    end
  end

  @doc """
  The address with a likely typo in its domain corrected, or `nil` when there
  is nothing to suggest (or the check is off).

      iex> PhoenixKit.Users.EmailDomain.suggest("ann@gmial.com")
      "ann@gmail.com"
  """
  @spec suggestion(term()) :: String.t() | nil
  def suggestion(email), do: if(enabled?(), do: suggest(email))

  @doc "`suggestion/1` without the switch: the pure rule."
  @spec suggest(term()) :: String.t() | nil
  def suggest(email) when is_binary(email) do
    with [local, domain] when local != "" <- split(email),
         false <- domain in @known_domains,
         corrected when is_binary(corrected) <- correct(domain) do
      local <> "@" <> corrected
    else
      _ -> nil
    end
  end

  def suggest(_), do: nil

  # --- The typo rule --------------------------------------------------------

  defp correct(domain) do
    fixed = fix_tld(domain)

    cond do
      fixed in @known_domains -> fixed
      near = Enum.find(@known_domains, &(distance(fixed, &1) == 1)) -> near
      fixed != domain -> fixed
      true -> nil
    end
  end

  defp fix_tld(domain) do
    case String.split(domain, ".") do
      [_ | _] = labels when length(labels) > 1 ->
        {tld, rest} = List.pop_at(labels, -1)
        Enum.join(rest ++ [Map.get(@tld_typos, tld, tld)], ".")

      _ ->
        domain
    end
  end

  # Edits between two short strings, a swap of neighbours counting as one
  # (optimal string alignment): "gmial" is one away from "gmail".
  @doc false
  @spec distance(String.t(), String.t()) :: non_neg_integer()
  def distance(a, b) do
    a = String.to_charlist(a)
    b = String.to_charlist(b)
    first = Enum.to_list(0..length(b))

    {_, last, _} =
      a
      |> Enum.with_index(1)
      |> Enum.reduce({nil, first, nil}, fn {ca, i}, {before_prev, prev, prev_char} ->
        row = next_row(ca, i, b, prev, before_prev, prev_char)
        {prev, row, ca}
      end)

    List.last(last)
  end

  defp next_row(ca, i, b, prev, before_prev, prev_char) do
    {row, _} =
      b
      |> Enum.with_index(1)
      |> Enum.reduce({[i], nil}, fn {cb, j}, {[left | _] = acc, last_b} ->
        cost = if ca == cb, do: 0, else: 1

        value =
          Enum.min([Enum.at(prev, j) + 1, left + 1, Enum.at(prev, j - 1) + cost])

        value =
          if before_prev && ca == last_b && cb == prev_char,
            do: min(value, Enum.at(before_prev, j - 2) + 1),
            else: value

        {[value | acc], cb}
      end)

    Enum.reverse(row)
  end

  # --- DNS ------------------------------------------------------------------

  defp mail_host(domain) do
    case resolve(domain, :mx) do
      {:ok, []} -> address_host(domain)
      {:ok, hosts} -> if Enum.all?(hosts, &null_mx?/1), do: {:error, :no_mail_host}, else: :ok
      {:error, :nxdomain} -> {:error, :no_mail_host}
      _ -> :ok
    end
  end

  # No MX record: mail goes to the domain's own address, if it has one.
  defp address_host(domain) do
    case {resolve(domain, :a), resolve(domain, :aaaa)} do
      {{:error, :nxdomain}, _} -> {:error, :no_mail_host}
      {{:ok, []}, {:ok, []}} -> {:error, :no_mail_host}
      _ -> :ok
    end
  end

  defp null_mx?(host), do: host in ["", "."]

  # `{:ok, hosts}` (MX: the exchange names; A/AAAA: one entry per address),
  # `{:error, :nxdomain}`, or `{:error, :unknown}` for no usable answer.
  # Tests replace it: `config :phoenix_kit, :email_domain_resolver, {Mod, :fun}`,
  # called with the domain and the record type.
  defp resolve(domain, type) do
    case Application.get_env(:phoenix_kit, :email_domain_resolver) do
      {module, function} -> apply(module, function, [domain, type])
      _ -> dns(domain, type)
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp dns(domain, type) do
    case :inet_res.resolve(String.to_charlist(domain), :in, type, [timeout: @timeout], @timeout) do
      {:ok, message} ->
        {:ok, answers(message, type)}

      {:error, :nxdomain} ->
        {:error, :nxdomain}

      {:error, {:nxdomain, _message}} ->
        {:error, :nxdomain}

      _ ->
        {:error, :unknown}
    end
  end

  defp answers(message, type) do
    message
    |> :inet_dns.msg(:anlist)
    |> Enum.filter(&(:inet_dns.rr(&1, :type) == type))
    |> Enum.map(fn record ->
      case :inet_dns.rr(record, :data) do
        {_preference, exchange} when type == :mx -> to_string(exchange)
        _address -> "address"
      end
    end)
  end

  # --- The address ----------------------------------------------------------

  # The domain to look up, or `:skip` for one DNS cannot be asked about as it
  # stands (no domain, an address literal, non-ASCII, not a hostname).
  defp lookup_domain(email) when is_binary(email) do
    with [_local, domain] <- split(email),
         true <- byte_size(domain) <= 253,
         true <- String.match?(domain, ~r/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/) do
      {:ok, domain}
    else
      _ -> :skip
    end
  end

  defp lookup_domain(_), do: :skip

  defp split(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@") do
      [local, domain] -> [local, String.trim_trailing(domain, ".")]
      _ -> :error
    end
  end
end
