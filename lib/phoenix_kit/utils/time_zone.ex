defmodule PhoenixKit.Utils.TimeZone do
  @moduledoc """
  Timezone identity for users and for the site: the picker list, the label for
  a stored value, and the one place a `DateTime` is moved into someone's zone.

  ## Why IANA ids and not an offset

  This used to store an integer offset — `"2"` for a row labelled
  "UTC+2 (Kyiv, Athens, Helsinki, Cairo, Johannesburg)". A number cannot carry
  a location, and that broke in three compounding ways:

    * **The labels were winter times.** Kyiv, Athens, Helsinki and Cairo are
      all UTC+3 from spring to autumn, so for half the year the row named
      cities that were not on the offset it claimed.
    * **The rows mixed zones that only agree in winter.** Johannesburg is
      UTC+2 every day of the year; the other four are not. One row could not be
      right for all of them at once.
    * **A stored offset cannot follow DST.** Pick Helsinki in January and `"2"`
      is written down; come summer Helsinki is UTC+3 and every timestamp shown
      is an hour behind until the profile is edited by hand.

  An IANA id names the *place*. `Europe/Warsaw` is UTC+1 in January and UTC+2
  in August without anything being re-saved, and it stays correct while the
  person travels.

  ## Which function for what

  Every conversion is per instant — a named zone follows daylight saving on
  the date being converted, never on the day a preference was saved:

    * `for_viewer/1` — the value a page should use for a scope, a user, or
      nobody (profile → site setting → `"0"`).
    * `shift/2` — a UTC instant as a wall clock in the zone (display).
    * `from_wall/2` — a typed wall clock (`NaiveDateTime`) as the UTC instant
      (a `datetime-local` input, a booking slot).
    * `date_start/2` — the UTC instant a local date begins (day windows).
    * `local_date/2` — the local date of an instant ("today").
    * `day_start/2` — `date_start/2` for the local date of now, or of `at`.
    * `offset_seconds/2` — the offset at one instant, for the rare place that
      genuinely needs a scalar (a label). Never add it to another instant.

  ## Legacy values

  Rows written before this change still hold offsets, and they keep working:
  `shift/2` reads `"2"` as a fixed +2 exactly as before, so nobody's
  timestamps move underneath them. Such a value is **not** upgraded
  automatically — `"2"` is genuinely ambiguous between `Europe/Warsaw` in
  summer and `Africa/Johannesburg` in any season, and guessing would put a
  location on the account that its owner never chose. `legacy_offset?/1` marks
  them so the UI can ask.

  `"5.5"` and `"9.5"` also start shifting for the first time here. The old
  code parsed offsets with `Integer.parse/1` and required an empty remainder,
  so `"5.5"` left `".5"` over, failed the match, and returned the timestamp
  **unshifted** — every account on UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)
  or UTC+9:30 (Adelaide, Darwin) was silently reading UTC.

  ## The list

  `identifiers/0` is the IANA region list, aliases included. Aliases are kept
  on purpose: tzdata links `Europe/Oslo`, `Europe/Stockholm` and
  `Europe/Copenhagen` to `Europe/Berlin`, and dropping them to "canonical"
  entries would leave a Norwegian unable to find Oslo — the same complaint
  that started this ("Warsaw is missing"). Every id is asserted resolvable
  against the compiled tz database in `time_zone_test.exs`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @database Tz.TimeZoneDatabase

  # Zones grouped by IDENTICAL year-round behaviour — same offset AND same
  # daylight-saving rule — so a row can never again claim cities that only
  # agree for half the year (Johannesburg does not switch; Helsinki does, and
  # the old list had them sharing "UTC+2").
  #
  # DERIVED, not hand-written: the membership comes from sampling every zone
  # across two years and grouping by the resulting sequence of offsets.
  # `time_zone_test.exs` re-derives it from the compiled tz database and fails
  # if this table has drifted — which is how the previous list rotted, city by
  # city, as countries changed their rules.
  #
  # The `cities` string is the one curated part: the machine picks coherent
  # membership but terrible names (it offered "Ceuta, Longyearbyen, Jan Mayen"
  # for central Europe), so the label lists the best-known members instead. The
  # same test asserts every named city really belongs to its group.
  @groups [
    %{
      rep: "Pacific/Midway",
      dst: false,
      cities: "Midway, Niue, Pago Pago, Samoa",
      zones: [
        "Pacific/Midway",
        "Pacific/Niue",
        "Pacific/Pago_Pago",
        "Pacific/Samoa"
      ]
    },
    %{
      rep: "Pacific/Honolulu",
      dst: false,
      cities: "Honolulu, Rarotonga, Tahiti, Johnston",
      zones: [
        "Pacific/Honolulu",
        "Pacific/Johnston",
        "Pacific/Rarotonga",
        "Pacific/Tahiti"
      ]
    },
    %{
      rep: "Pacific/Marquesas",
      dst: false,
      cities: "Marquesas",
      zones: [
        "Pacific/Marquesas"
      ]
    },
    %{
      rep: "America/Adak",
      dst: true,
      cities: "Adak, Atka",
      zones: [
        "America/Adak",
        "America/Atka"
      ]
    },
    %{
      rep: "Pacific/Gambier",
      dst: false,
      cities: "Gambier",
      zones: [
        "Pacific/Gambier"
      ]
    },
    %{
      rep: "America/Anchorage",
      dst: true,
      cities: "Anchorage, Juneau, Metlakatla, Nome",
      zones: [
        "America/Anchorage",
        "America/Juneau",
        "America/Metlakatla",
        "America/Nome",
        "America/Sitka",
        "America/Yakutat"
      ]
    },
    %{
      rep: "Pacific/Pitcairn",
      dst: false,
      cities: "Pitcairn",
      zones: [
        "Pacific/Pitcairn"
      ]
    },
    %{
      rep: "America/Los_Angeles",
      dst: true,
      cities: "Los Angeles, Tijuana, Ensenada, Santa Isabel",
      zones: [
        "America/Ensenada",
        "America/Los_Angeles",
        "America/Santa_Isabel",
        "America/Tijuana"
      ]
    },
    %{
      rep: "America/Phoenix",
      dst: false,
      cities: "Phoenix, Creston, Dawson, Dawson Creek",
      zones: [
        "America/Creston",
        "America/Dawson",
        "America/Dawson_Creek",
        "America/Fort_Nelson",
        "America/Hermosillo",
        "America/Mazatlan",
        "America/Phoenix",
        "America/Whitehorse"
      ]
    },
    %{
      rep: "America/Vancouver",
      dst: true,
      cities: "Vancouver",
      zones: [
        "America/Vancouver"
      ]
    },
    %{
      rep: "America/Denver",
      dst: true,
      cities: "Denver, Boise, Cambridge Bay, Ciudad Juarez",
      zones: [
        "America/Boise",
        "America/Cambridge_Bay",
        "America/Ciudad_Juarez",
        "America/Denver",
        "America/Edmonton",
        "America/Inuvik",
        "America/Shiprock",
        "America/Yellowknife"
      ]
    },
    %{
      rep: "America/Mexico_City",
      dst: false,
      cities: "Mexico City, Bahia Banderas, Belize, Chihuahua",
      zones: [
        "America/Bahia_Banderas",
        "America/Belize",
        "America/Chihuahua",
        "America/Costa_Rica",
        "America/El_Salvador",
        "America/Guatemala",
        "America/Managua",
        "America/Merida",
        "America/Mexico_City",
        "America/Monterrey",
        "America/Regina",
        "America/Swift_Current",
        "America/Tegucigalpa",
        "Pacific/Galapagos"
      ]
    },
    %{
      rep: "Pacific/Easter",
      dst: true,
      cities: "Easter",
      zones: [
        "Pacific/Easter"
      ]
    },
    %{
      rep: "America/Bogota",
      dst: false,
      cities: "Bogota, Lima, Atikokan, Cancun",
      zones: [
        "America/Atikokan",
        "America/Bogota",
        "America/Cancun",
        "America/Cayman",
        "America/Coral_Harbour",
        "America/Eirunepe",
        "America/Guayaquil",
        "America/Jamaica",
        "America/Lima",
        "America/Panama",
        "America/Porto_Acre",
        "America/Rio_Branco"
      ]
    },
    %{
      rep: "America/Chicago",
      dst: true,
      cities: "Chicago, Knox, Tell City, Matamoros",
      zones: [
        "America/Chicago",
        "America/Indiana/Knox",
        "America/Indiana/Tell_City",
        "America/Matamoros",
        "America/Menominee",
        "America/North_Dakota/Beulah",
        "America/North_Dakota/Center",
        "America/North_Dakota/New_Salem",
        "America/Ojinaga",
        "America/Rainy_River",
        "America/Rankin_Inlet",
        "America/Resolute",
        "America/Winnipeg"
      ]
    },
    %{
      rep: "America/Caracas",
      dst: false,
      cities: "Caracas, Anguilla, Antigua, Aruba",
      zones: [
        "America/Anguilla",
        "America/Antigua",
        "America/Aruba",
        "America/Barbados",
        "America/Blanc-Sablon",
        "America/Boa_Vista",
        "America/Campo_Grande",
        "America/Caracas",
        "America/Cuiaba",
        "America/Curacao",
        "America/Dominica",
        "America/Grenada",
        "America/Guadeloupe",
        "America/Guyana",
        "America/Kralendijk",
        "America/La_Paz",
        "America/Lower_Princes",
        "America/Manaus",
        "America/Marigot",
        "America/Martinique",
        "America/Montserrat",
        "America/Port_of_Spain",
        "America/Porto_Velho",
        "America/Puerto_Rico",
        "America/Santo_Domingo",
        "America/St_Barthelemy",
        "America/St_Kitts",
        "America/St_Lucia",
        "America/St_Thomas",
        "America/St_Vincent",
        "America/Tortola",
        "America/Virgin"
      ]
    },
    %{
      rep: "America/New_York",
      dst: true,
      cities: "New York, Toronto, Detroit, Grand Turk",
      zones: [
        "America/Detroit",
        "America/Grand_Turk",
        "America/Havana",
        "America/Indiana/Indianapolis",
        "America/Indiana/Marengo",
        "America/Indiana/Petersburg",
        "America/Indiana/Vevay",
        "America/Indiana/Vincennes",
        "America/Indiana/Winamac",
        "America/Iqaluit",
        "America/Kentucky/Louisville",
        "America/Kentucky/Monticello",
        "America/Montreal",
        "America/Nassau",
        "America/New_York",
        "America/Nipigon",
        "America/Pangnirtung",
        "America/Port-au-Prince",
        "America/Thunder_Bay",
        "America/Toronto"
      ]
    },
    %{
      rep: "America/Santiago",
      dst: true,
      cities: "Santiago",
      zones: [
        "America/Santiago"
      ]
    },
    %{
      rep: "America/Halifax",
      dst: true,
      cities: "Halifax, Glace Bay, Goose Bay, Moncton",
      zones: [
        "America/Glace_Bay",
        "America/Goose_Bay",
        "America/Halifax",
        "America/Moncton",
        "America/Thule",
        "Atlantic/Bermuda"
      ]
    },
    %{
      rep: "America/Sao_Paulo",
      dst: false,
      cities: "Sao Paulo, Buenos Aires, Araguaina, Catamarca",
      zones: [
        "America/Araguaina",
        "America/Argentina/Buenos_Aires",
        "America/Argentina/Catamarca",
        "America/Argentina/Cordoba",
        "America/Argentina/Jujuy",
        "America/Argentina/La_Rioja",
        "America/Argentina/Mendoza",
        "America/Argentina/Rio_Gallegos",
        "America/Argentina/Salta",
        "America/Argentina/San_Juan",
        "America/Argentina/San_Luis",
        "America/Argentina/Tucuman",
        "America/Argentina/Ushuaia",
        "America/Asuncion",
        "America/Bahia",
        "America/Belem",
        "America/Cayenne",
        "America/Coyhaique",
        "America/Fortaleza",
        "America/Maceio",
        "America/Montevideo",
        "America/Paramaribo",
        "America/Punta_Arenas",
        "America/Recife",
        "America/Santarem",
        "America/Sao_Paulo",
        "Antarctica/Palmer",
        "Antarctica/Rothera",
        "Atlantic/Stanley"
      ]
    },
    %{
      rep: "America/St_Johns",
      dst: true,
      cities: "St Johns",
      zones: [
        "America/St_Johns"
      ]
    },
    %{
      rep: "America/Miquelon",
      dst: true,
      cities: "Miquelon",
      zones: [
        "America/Miquelon"
      ]
    },
    %{
      rep: "America/Noronha",
      dst: false,
      cities: "Noronha, South Georgia",
      zones: [
        "America/Noronha",
        "Atlantic/South_Georgia"
      ]
    },
    %{
      rep: "America/Nuuk",
      dst: true,
      cities: "Nuuk, Scoresbysund",
      zones: [
        "America/Nuuk",
        "America/Scoresbysund"
      ]
    },
    %{
      rep: "Atlantic/Cape_Verde",
      dst: false,
      cities: "Cape Verde",
      zones: [
        "Atlantic/Cape_Verde"
      ]
    },
    %{
      rep: "Africa/Accra",
      dst: false,
      cities: "Accra, Reykjavik, Abidjan, Bamako",
      zones: [
        "Africa/Abidjan",
        "Africa/Accra",
        "Africa/Bamako",
        "Africa/Banjul",
        "Africa/Bissau",
        "Africa/Conakry",
        "Africa/Dakar",
        "Africa/Freetown",
        "Africa/Lome",
        "Africa/Monrovia",
        "Africa/Nouakchott",
        "Africa/Ouagadougou",
        "Africa/Sao_Tome",
        "Africa/Timbuktu",
        "America/Danmarkshavn",
        "Atlantic/Reykjavik",
        "Atlantic/St_Helena"
      ]
    },
    %{
      rep: "Atlantic/Azores",
      dst: true,
      cities: "Azores",
      zones: [
        "Atlantic/Azores"
      ]
    },
    %{
      rep: "Africa/Casablanca",
      dst: true,
      cities: "Casablanca, El Aaiun",
      zones: [
        "Africa/Casablanca",
        "Africa/El_Aaiun"
      ]
    },
    %{
      rep: "Africa/Lagos",
      dst: false,
      cities: "Lagos, Algiers, Bangui, Brazzaville",
      zones: [
        "Africa/Algiers",
        "Africa/Bangui",
        "Africa/Brazzaville",
        "Africa/Douala",
        "Africa/Kinshasa",
        "Africa/Lagos",
        "Africa/Libreville",
        "Africa/Luanda",
        "Africa/Malabo",
        "Africa/Ndjamena",
        "Africa/Niamey",
        "Africa/Porto-Novo",
        "Africa/Tunis"
      ]
    },
    %{
      rep: "Europe/London",
      dst: true,
      cities: "London, Dublin, Lisbon, Canary",
      zones: [
        "Atlantic/Canary",
        "Atlantic/Faroe",
        "Atlantic/Madeira",
        "Europe/Belfast",
        "Europe/Dublin",
        "Europe/Guernsey",
        "Europe/Isle_of_Man",
        "Europe/Jersey",
        "Europe/Lisbon",
        "Europe/London"
      ]
    },
    %{
      rep: "Africa/Johannesburg",
      dst: false,
      cities: "Johannesburg, Blantyre, Bujumbura, Gaborone",
      zones: [
        "Africa/Blantyre",
        "Africa/Bujumbura",
        "Africa/Gaborone",
        "Africa/Harare",
        "Africa/Johannesburg",
        "Africa/Juba",
        "Africa/Khartoum",
        "Africa/Kigali",
        "Africa/Lubumbashi",
        "Africa/Lusaka",
        "Africa/Maputo",
        "Africa/Maseru",
        "Africa/Mbabane",
        "Africa/Tripoli",
        "Africa/Windhoek",
        "Europe/Kaliningrad"
      ]
    },
    %{
      rep: "Antarctica/Troll",
      dst: true,
      cities: "Troll",
      zones: [
        "Antarctica/Troll"
      ]
    },
    %{
      rep: "Europe/Paris",
      dst: true,
      cities: "Paris, Berlin, Madrid, Rome",
      zones: [
        "Africa/Ceuta",
        "Arctic/Longyearbyen",
        "Atlantic/Jan_Mayen",
        "Europe/Amsterdam",
        "Europe/Andorra",
        "Europe/Belgrade",
        "Europe/Berlin",
        "Europe/Bratislava",
        "Europe/Brussels",
        "Europe/Budapest",
        "Europe/Busingen",
        "Europe/Copenhagen",
        "Europe/Gibraltar",
        "Europe/Ljubljana",
        "Europe/Luxembourg",
        "Europe/Madrid",
        "Europe/Malta",
        "Europe/Monaco",
        "Europe/Oslo",
        "Europe/Paris",
        "Europe/Podgorica",
        "Europe/Prague",
        "Europe/Rome",
        "Europe/San_Marino",
        "Europe/Sarajevo",
        "Europe/Skopje",
        "Europe/Stockholm",
        "Europe/Tirane",
        "Europe/Vaduz",
        "Europe/Vatican",
        "Europe/Vienna",
        "Europe/Warsaw",
        "Europe/Zagreb",
        "Europe/Zurich"
      ]
    },
    %{
      rep: "Europe/Athens",
      dst: true,
      cities: "Athens, Helsinki, Tallinn, Riga",
      zones: [
        "Africa/Cairo",
        "Asia/Beirut",
        "Asia/Famagusta",
        "Asia/Gaza",
        "Asia/Hebron",
        "Asia/Jerusalem",
        "Asia/Nicosia",
        "Asia/Tel_Aviv",
        "Europe/Athens",
        "Europe/Bucharest",
        "Europe/Chisinau",
        "Europe/Helsinki",
        "Europe/Kyiv",
        "Europe/Mariehamn",
        "Europe/Nicosia",
        "Europe/Riga",
        "Europe/Sofia",
        "Europe/Tallinn",
        "Europe/Tiraspol",
        "Europe/Vilnius"
      ]
    },
    %{
      rep: "Europe/Istanbul",
      dst: false,
      cities: "Istanbul, Moscow, Minsk, Nairobi",
      zones: [
        "Africa/Addis_Ababa",
        "Africa/Asmara",
        "Africa/Dar_es_Salaam",
        "Africa/Djibouti",
        "Africa/Kampala",
        "Africa/Mogadishu",
        "Africa/Nairobi",
        "Antarctica/Syowa",
        "Asia/Aden",
        "Asia/Amman",
        "Asia/Baghdad",
        "Asia/Bahrain",
        "Asia/Damascus",
        "Asia/Istanbul",
        "Asia/Kuwait",
        "Asia/Qatar",
        "Asia/Riyadh",
        "Europe/Istanbul",
        "Europe/Kirov",
        "Europe/Minsk",
        "Europe/Moscow",
        "Europe/Simferopol",
        "Europe/Volgograd",
        "Indian/Antananarivo",
        "Indian/Comoro",
        "Indian/Mayotte"
      ]
    },
    %{
      rep: "Asia/Tehran",
      dst: false,
      cities: "Tehran",
      zones: [
        "Asia/Tehran"
      ]
    },
    %{
      rep: "Asia/Dubai",
      dst: false,
      cities: "Dubai, Baku, Tbilisi, Yerevan",
      zones: [
        "Asia/Baku",
        "Asia/Dubai",
        "Asia/Muscat",
        "Asia/Tbilisi",
        "Asia/Yerevan",
        "Europe/Astrakhan",
        "Europe/Samara",
        "Europe/Saratov",
        "Europe/Ulyanovsk",
        "Indian/Mahe",
        "Indian/Mauritius",
        "Indian/Reunion"
      ]
    },
    %{
      rep: "Asia/Kabul",
      dst: false,
      cities: "Kabul",
      zones: [
        "Asia/Kabul"
      ]
    },
    %{
      rep: "Asia/Karachi",
      dst: false,
      cities: "Karachi, Almaty, Tashkent, Mawson",
      zones: [
        "Antarctica/Mawson",
        "Antarctica/Vostok",
        "Asia/Almaty",
        "Asia/Aqtau",
        "Asia/Aqtobe",
        "Asia/Ashgabat",
        "Asia/Atyrau",
        "Asia/Dushanbe",
        "Asia/Karachi",
        "Asia/Oral",
        "Asia/Qostanay",
        "Asia/Qyzylorda",
        "Asia/Samarkand",
        "Asia/Tashkent",
        "Asia/Yekaterinburg",
        "Indian/Kerguelen",
        "Indian/Maldives"
      ]
    },
    %{
      rep: "Asia/Kolkata",
      dst: false,
      cities: "Kolkata, Colombo",
      zones: [
        "Asia/Colombo",
        "Asia/Kolkata"
      ]
    },
    %{
      rep: "Asia/Kathmandu",
      dst: false,
      cities: "Kathmandu",
      zones: [
        "Asia/Kathmandu"
      ]
    },
    %{
      rep: "Asia/Dhaka",
      dst: false,
      cities: "Dhaka, Bishkek, Omsk, Thimphu",
      zones: [
        "Asia/Bishkek",
        "Asia/Dhaka",
        "Asia/Kashgar",
        "Asia/Omsk",
        "Asia/Thimphu",
        "Asia/Urumqi",
        "Indian/Chagos"
      ]
    },
    %{
      rep: "Asia/Yangon",
      dst: false,
      cities: "Yangon, Cocos",
      zones: [
        "Asia/Yangon",
        "Indian/Cocos"
      ]
    },
    %{
      rep: "Asia/Bangkok",
      dst: false,
      cities: "Bangkok, Jakarta, Ho Chi Minh, Davis",
      zones: [
        "Antarctica/Davis",
        "Asia/Bangkok",
        "Asia/Barnaul",
        "Asia/Ho_Chi_Minh",
        "Asia/Hovd",
        "Asia/Jakarta",
        "Asia/Krasnoyarsk",
        "Asia/Novokuznetsk",
        "Asia/Novosibirsk",
        "Asia/Phnom_Penh",
        "Asia/Pontianak",
        "Asia/Tomsk",
        "Asia/Vientiane",
        "Indian/Christmas"
      ]
    },
    %{
      rep: "Asia/Singapore",
      dst: false,
      cities: "Singapore, Hong Kong, Shanghai, Taipei",
      zones: [
        "Antarctica/Casey",
        "Asia/Brunei",
        "Asia/Chongqing",
        "Asia/Harbin",
        "Asia/Hong_Kong",
        "Asia/Irkutsk",
        "Asia/Kuala_Lumpur",
        "Asia/Kuching",
        "Asia/Macau",
        "Asia/Makassar",
        "Asia/Manila",
        "Asia/Shanghai",
        "Asia/Singapore",
        "Asia/Taipei",
        "Asia/Ulaanbaatar",
        "Australia/Perth"
      ]
    },
    %{
      rep: "Australia/Eucla",
      dst: false,
      cities: "Eucla",
      zones: [
        "Australia/Eucla"
      ]
    },
    %{
      rep: "Asia/Seoul",
      dst: false,
      cities: "Seoul, Tokyo, Chita, Dili",
      zones: [
        "Asia/Chita",
        "Asia/Dili",
        "Asia/Jayapura",
        "Asia/Khandyga",
        "Asia/Pyongyang",
        "Asia/Seoul",
        "Asia/Tokyo",
        "Asia/Yakutsk",
        "Pacific/Palau"
      ]
    },
    %{
      rep: "Australia/Adelaide",
      dst: true,
      cities: "Adelaide, Broken Hill, Yancowinna",
      zones: [
        "Australia/Adelaide",
        "Australia/Broken_Hill",
        "Australia/Yancowinna"
      ]
    },
    %{
      rep: "Australia/Darwin",
      dst: false,
      cities: "Darwin",
      zones: [
        "Australia/Darwin"
      ]
    },
    %{
      rep: "Australia/Brisbane",
      dst: false,
      cities: "Brisbane, DumontDUrville, Ust-Nera, Vladivostok",
      zones: [
        "Antarctica/DumontDUrville",
        "Asia/Ust-Nera",
        "Asia/Vladivostok",
        "Australia/Brisbane",
        "Australia/Lindeman",
        "Pacific/Chuuk",
        "Pacific/Guam",
        "Pacific/Port_Moresby",
        "Pacific/Saipan",
        "Pacific/Yap"
      ]
    },
    %{
      rep: "Australia/Sydney",
      dst: true,
      cities: "Sydney, Melbourne, Macquarie, Hobart",
      zones: [
        "Antarctica/Macquarie",
        "Australia/Canberra",
        "Australia/Currie",
        "Australia/Hobart",
        "Australia/Melbourne",
        "Australia/Sydney"
      ]
    },
    %{
      rep: "Australia/Lord_Howe",
      dst: true,
      cities: "Lord Howe",
      zones: [
        "Australia/Lord_Howe"
      ]
    },
    %{
      rep: "Asia/Magadan",
      dst: false,
      cities: "Magadan, Sakhalin, Srednekolymsk, Bougainville",
      zones: [
        "Asia/Magadan",
        "Asia/Sakhalin",
        "Asia/Srednekolymsk",
        "Pacific/Bougainville",
        "Pacific/Efate",
        "Pacific/Guadalcanal",
        "Pacific/Kosrae",
        "Pacific/Noumea",
        "Pacific/Pohnpei"
      ]
    },
    %{
      rep: "Pacific/Norfolk",
      dst: true,
      cities: "Norfolk",
      zones: [
        "Pacific/Norfolk"
      ]
    },
    %{
      rep: "Pacific/Auckland",
      dst: true,
      cities: "Auckland, McMurdo",
      zones: [
        "Antarctica/McMurdo",
        "Pacific/Auckland"
      ]
    },
    %{
      rep: "Pacific/Fiji",
      dst: false,
      cities: "Fiji, Anadyr, Kamchatka, Funafuti",
      zones: [
        "Asia/Anadyr",
        "Asia/Kamchatka",
        "Pacific/Fiji",
        "Pacific/Funafuti",
        "Pacific/Kwajalein",
        "Pacific/Majuro",
        "Pacific/Nauru",
        "Pacific/Tarawa",
        "Pacific/Wake",
        "Pacific/Wallis"
      ]
    },
    %{
      rep: "Pacific/Chatham",
      dst: true,
      cities: "Chatham",
      zones: [
        "Pacific/Chatham"
      ]
    },
    %{
      rep: "Pacific/Apia",
      dst: false,
      cities: "Apia, Fakaofo, Kanton, Tongatapu",
      zones: [
        "Pacific/Apia",
        "Pacific/Fakaofo",
        "Pacific/Kanton",
        "Pacific/Tongatapu"
      ]
    },
    %{
      rep: "Pacific/Kiritimati",
      dst: false,
      cities: "Kiritimati",
      zones: [
        "Pacific/Kiritimati"
      ]
    }
  ]

  @identifiers @groups |> Enum.flat_map(& &1.zones) |> Enum.sort()

  @zone_to_group for group <- @groups, zone <- group.zones, into: %{}, do: {zone, group.rep}

  @doc """
  Every selectable IANA identifier, sorted.
  """
  @spec identifiers() :: [String.t()]
  def identifiers, do: @identifiers

  @doc """
  The timezone database backing every lookup here.

  Passed explicitly to `DateTime.shift_zone/3` rather than set as
  `config :elixir, :time_zone_database`: this is a library, and a library
  reaching into the host's Elixir config to swap a global would decide for
  every other dependency in the app too.
  """
  @spec database() :: module()
  def database, do: @database

  @doc """
  Picker options as `{label, identifier}`, ordered by current UTC offset.

  One row per behaviour group — 59, not 447 — so the list stays browsable while
  every row remains a real zone that follows its own daylight-saving rule.
  Selecting a row stores that group's representative; everyone in the group
  behaves identically all year, so the choice is right for all of them.

  Offsets are computed now, not baked into the string: the central-European row
  reads `(UTC+01:00)` in January and `(UTC+02:00)` in July. Freezing that number
  is what made the old list wrong for half the year.

  Pass the currently-stored value as `:selected`. When it is a zone that is not
  itself a representative — the usual case once detection has stored somewhere
  precise like `Europe/Tallinn` — it is prepended as its own row, so the list
  stays short without ever misreporting what is saved.
  """
  @spec options(keyword()) :: [{String.t(), String.t()}]
  def options(opts \\ []) do
    now = DateTime.utc_now()

    rows =
      @groups
      |> Enum.map(fn group -> {zone_offset_at(now, group.rep), group} end)
      |> Enum.sort_by(fn {offset, group} -> {offset, group.cities} end)
      |> Enum.map(fn {offset, group} -> {group_label(offset, group), group.rep} end)

    case selected_extra_row(opts[:selected], now) do
      nil -> rows
      row -> [row | rows]
    end
  end

  defp group_label(offset, group) do
    suffix = if group.dst, do: " — " <> gettext("summer time"), else: ""
    "(UTC#{format_offset(offset)}) #{group.cities}#{suffix}"
  end

  # Anything stored that is not already a row has to be added as one.
  #
  # This is load-bearing, not a nicety: a <select> whose current value matches
  # no <option> renders with the FIRST option selected, and the next save of
  # that form writes it. Without this, every account still holding a pre-IANA
  # offset — and the site's own `time_zone` setting, which holds "0" on every
  # existing installation — would be silently rewritten the first time anyone
  # touched an unrelated field on the same page.
  defp selected_extra_row(selected, now) when is_binary(selected) and selected != "" do
    cond do
      identifier?(selected) and not representative?(selected) ->
        {"(UTC#{format_offset(zone_offset_at(now, selected))}) #{selected} — your location",
         selected}

      legacy_offset?(selected) ->
        {:ok, hours} = parse_offset(selected)

        {"(UTC#{format_offset(round(hours * 3600))}) fixed offset — set before timezones were named",
         selected}

      true ->
        nil
    end
  end

  defp selected_extra_row(_selected, _now), do: nil

  @doc """
  The representative zone for whichever group `zone` belongs to, or `nil`.
  """
  @spec group_for(String.t()) :: String.t() | nil
  def group_for(zone) when is_binary(zone), do: Map.get(@zone_to_group, zone)
  def group_for(_zone), do: nil

  @doc """
  Whether `zone` is one of the group representatives the picker lists directly.
  """
  @spec representative?(String.t()) :: boolean()
  def representative?(zone) when is_binary(zone), do: group_for(zone) == zone
  def representative?(_zone), do: false

  @doc """
  Whether two zones behave identically all year — same offset, same DST rule.

  Used by the mismatch check: someone detected in `Europe/Tallinn` whose account
  says `Europe/Helsinki` is not misconfigured, because the two never disagree.
  """
  @spec same_group?(String.t() | nil, String.t() | nil) :: boolean()
  def same_group?(a, b) when is_binary(a) and is_binary(b) do
    case {group_for(a), group_for(b)} do
      {nil, _} -> false
      {_, nil} -> false
      {group, group} -> true
      _ -> false
    end
  end

  def same_group?(_a, _b), do: false

  @doc """
  Whether `a` and `b` render the same wall-clock time right now.

  `same_group?/2` only ever returns true for two identifiers — a legacy
  offset is not a group member, so comparing a browser-detected zone against
  a site's `time_zone` setting (which is the legacy offset `"0"` on every
  install that has never touched that setting) always failed `same_group?`,
  even from a browser genuinely on UTC+0. This compares current effective
  offset instead, which is defined for a legacy offset too.
  """
  @spec effectively_same?(String.t() | nil, String.t() | nil) :: boolean()
  def effectively_same?(a, b) when is_binary(a) and is_binary(b) do
    case {identifier?(a), identifier?(b)} do
      {true, true} -> same_group?(a, b)
      _ -> current_offset(a) != nil and current_offset(a) == current_offset(b)
    end
  end

  def effectively_same?(_a, _b), do: false

  defp current_offset(value) do
    now = DateTime.utc_now()

    cond do
      identifier?(value) ->
        zone_offset_at(now, value)

      legacy_offset?(value) ->
        {:ok, hours} = parse_offset(value)
        round(hours * 3600)

      true ->
        nil
    end
  end

  @doc """
  Human label for a stored value — an IANA id, a legacy offset, or nothing.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.label("Europe/Warsaw") =~ "Europe/Warsaw"
      true

      iex> PhoenixKit.Utils.TimeZone.label(nil)
      "Use System Default"

  """
  @spec label(String.t() | nil) :: String.t()
  def label(value) when value in [nil, ""], do: gettext("Use System Default")

  def label(value) do
    cond do
      identifier?(value) ->
        now = DateTime.utc_now()
        offset = zone_offset_at(now, value)

        # A representative renders as its picker row, so the value shown beside
        # a saved setting reads the same as the option that set it. Anything
        # else — a precise zone stored by detection — names itself.
        case Enum.find(@groups, &(&1.rep == value)) do
          nil -> "(UTC#{format_offset(offset)}) #{value}"
          group -> group_label(offset, group)
        end

      legacy_offset?(value) ->
        {:ok, hours} = parse_offset(value)
        "UTC#{format_offset(round(hours * 3600))}"

      true ->
        value
    end
  end

  @doc """
  Whether `value` is one of the selectable IANA identifiers.
  """
  @spec identifier?(term()) :: boolean()
  def identifier?(value) when is_binary(value), do: value in @identifiers
  def identifier?(_), do: false

  @doc """
  Whether `value` is a pre-IANA numeric offset, e.g. `"2"`, `"-5"`, `"5.5"`.

  Kept working by `shift/2`, but the UI should offer to replace it: the number
  says nothing about where the account holder is, so it cannot follow DST.
  """
  @spec legacy_offset?(term()) :: boolean()
  def legacy_offset?(value) when is_binary(value), do: match?({:ok, _}, parse_offset(value))
  def legacy_offset?(_), do: false

  @doc """
  Whether `value` is storable — an identifier, a legacy offset, or blank.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when value in [nil, ""], do: true
  def valid?(value), do: identifier?(value) or legacy_offset?(value)

  @doc """
  Moves `datetime` into the zone named by `value`.

  An identifier goes through `DateTime.shift_zone/3`, so DST is applied for the
  instant being shown rather than for the moment the preference was saved. A
  legacy offset is added as a fixed number of seconds. Anything unusable —
  including a zone the database cannot resolve — returns `datetime` untouched,
  because a page of timestamps is worth more than a crash over a preference.
  """
  @spec shift(DateTime.t(), String.t() | nil) :: DateTime.t()
  def shift(datetime, value) when value in [nil, ""], do: datetime

  def shift(%DateTime{} = datetime, value) do
    if identifier?(value) do
      case DateTime.shift_zone(datetime, value, @database) do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end
    else
      case parse_offset(value) do
        {:ok, hours} -> DateTime.add(datetime, round(hours * 3600), :second)
        :error -> datetime
      end
    end
  end

  def shift(datetime, _value), do: datetime

  @doc """
  Reads a wall-clock `NaiveDateTime` as local time in `value`, returning UTC.

  The inverse of `shift/2`, for a `datetime-local` input: the person typed
  09:00 meaning 09:00 where they are, and it has to be stored as an instant.

  Daylight saving makes this genuinely ambiguous twice a year. An hour that
  happens twice resolves to the **first** occurrence, and an hour that never
  happens resolves to the instant the clocks jump to — both deterministic, and
  both closer to what someone typing a time expects than an error would be.

  Returns `{:ok, datetime}` or `:error`.
  """
  @spec from_wall(NaiveDateTime.t(), String.t() | nil) :: {:ok, DateTime.t()} | :error
  def from_wall(%NaiveDateTime{} = naive, value) when value in [nil, ""] do
    DateTime.from_naive(naive, "Etc/UTC")
  end

  def from_wall(%NaiveDateTime{} = naive, value) do
    if identifier?(value) do
      naive
      |> DateTime.from_naive(value, @database)
      |> resolve_wall()
      |> case do
        {:ok, local} -> DateTime.shift_zone(local, "Etc/UTC", @database)
        :error -> :error
      end
    else
      case parse_offset(value) do
        {:ok, hours} ->
          naive
          |> NaiveDateTime.add(-round(hours * 3600), :second)
          |> DateTime.from_naive("Etc/UTC")

        :error ->
          :error
      end
    end
  end

  def from_wall(_naive, _value), do: :error

  @doc """
  Offset from UTC in seconds for either kind of stored value.

  A legacy offset (`"2"`, `"-5"`, `"5.5"`) is that offset. An IANA id has no
  single answer — `Europe/Warsaw` is +1 in January and +2 in August — so it is
  resolved **at an instant**, `at` or now.

  That snapshot is the honest limit of this function, and callers doing date
  arithmetic across a daylight-saving boundary want `shift/2` or `from_wall/2`
  instead, which are correct per-instant. It exists because several call sites
  genuinely need a scalar (a window offset, a comparison), and the alternative
  they had was `Float.parse/1` returning `0` for every named zone — silently
  computing in UTC on any site that used the picker, which since the move to
  IANA ids is every site that touched the setting.

  Unresolvable values give `0`, the same safe default as before.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.offset_seconds("2")
      7200

      iex> PhoenixKit.Utils.TimeZone.offset_seconds("5.5")
      19800

      iex> PhoenixKit.Utils.TimeZone.offset_seconds("nonsense")
      0

  """
  @spec offset_seconds(String.t() | nil, DateTime.t() | nil) :: integer()
  def offset_seconds(value, at \\ nil)
  def offset_seconds(value, _at) when value in [nil, ""], do: 0

  def offset_seconds(value, at) when is_binary(value) do
    if identifier?(value) do
      zone_offset_at(at || DateTime.utc_now(), value)
    else
      case parse_offset(value) do
        {:ok, hours} -> round(hours * 3600)
        :error -> 0
      end
    end
  end

  def offset_seconds(_value, _at), do: 0

  @doc """
  The UTC instant at which the current day began in `value`.

  For "how many X happened today", where *today* is the operator's day and not
  UTC's. Getting this wrong is invisible most of the day and then wrong every
  evening: a site on `Europe/Tallinn` (UTC+3) counting from UTC midnight loses
  everything between 21:00 and midnight local, every night.

  `at` overrides "now", for tests and for asking about another moment.
  Falls back to UTC midnight when the value cannot be resolved.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.day_start("0", ~U[2026-09-05 14:00:00Z])
      ~U[2026-09-05 00:00:00Z]

      iex> PhoenixKit.Utils.TimeZone.day_start("2", ~U[2026-09-05 00:30:00Z])
      ~U[2026-09-04 22:00:00Z]

  """
  @spec day_start(String.t() | nil, DateTime.t() | nil) :: DateTime.t()
  def day_start(value, at \\ nil) do
    now = at || DateTime.utc_now()

    local_midnight =
      now
      |> shift(value)
      |> DateTime.to_naive()
      |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 0}})

    case from_wall(local_midnight, value) do
      {:ok, utc} -> utc
      :error -> %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    end
  end

  @doc """
  The timezone value a page should use for `viewer` — their own
  `user_timezone` when set, else the site's `time_zone` setting, else `"0"`.

  Takes a `%Scope{}`, a user (a `%User{}` or any map, with or without the
  column — test scopes and degraded embeds carry partial maps), or `nil`.
  Always a string: an IANA id or a legacy offset, never a number, ready for
  `shift/2`, `from_wall/2`, `date_start/2` and `local_date/2`.

  This is the rule `PhoenixKit.Utils.Date.get_user_timezone/1` applies to a
  full `%User{}`, made total. Before it existed, five modules each carried
  their own copy of the fallback chain — and two of them disagreed with it.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.for_viewer(%{user_timezone: "Europe/Warsaw"})
      "Europe/Warsaw"

  """
  @spec for_viewer(PhoenixKit.Users.Auth.Scope.t() | map() | nil) :: String.t()
  def for_viewer(%PhoenixKit.Users.Auth.Scope{user: user}), do: for_viewer(user)

  def for_viewer(%{} = user) do
    case Map.get(user, :user_timezone) do
      value when is_binary(value) and value != "" -> value
      _ -> site_zone()
    end
  end

  def for_viewer(_viewer), do: site_zone()

  # `Settings.get_setting/2` already answers the default when the database
  # is unreachable, so nothing here needs rescuing.
  defp site_zone, do: PhoenixKit.Settings.get_setting("time_zone", "0")

  @doc """
  The UTC instant at which `date` begins in `value` — the lower bound of a
  viewer-local day, and (with the next date) the exclusive upper bound.

  Resolved for THAT date: `Europe/Tallinn` starts January 15 at 22:00Z the
  evening before and July 15 at 21:00Z. Subtracting one offset taken today
  from both bounds of a window — what several modules did — was an hour off
  for any window on the other side of a daylight-saving switch. A midnight
  that never happens (spring-forward at 00:00, as in Santiago) is the
  instant the clocks jump to; one that happens twice (fall-back at 00:00, as
  in Havana) is its first occurrence — either way the first instant of that
  date. Falls back to UTC midnight when the value cannot be resolved.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.date_start(~D[2026-07-15], "2")
      ~U[2026-07-14 22:00:00Z]

      iex> PhoenixKit.Utils.TimeZone.date_start(~D[2026-07-15], "nonsense")
      ~U[2026-07-15 00:00:00Z]

  """
  @spec date_start(Date.t(), String.t() | nil) :: DateTime.t()
  def date_start(%Date{} = date, value) do
    case from_wall(NaiveDateTime.new!(date, ~T[00:00:00]), value) do
      {:ok, utc} -> utc
      :error -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  @doc """
  The calendar date of `instant` in `value` — what "today" means to a viewer
  in that zone when `instant` is now.

  `Date.utc_today/0` is the wrong answer to that question for most of the
  world for part of every day: at 01:00 in Tallinn it is still yesterday in
  UTC, so a grid highlighted the wrong day and a "New event" prefilled the
  wrong date. Unresolvable values read as UTC.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.local_date(~U[2026-07-14 22:30:00Z], "2")
      ~D[2026-07-15]

      iex> PhoenixKit.Utils.TimeZone.local_date(~U[2026-07-14 22:30:00Z], "-5")
      ~D[2026-07-14]

  """
  @spec local_date(DateTime.t(), String.t() | nil) :: Date.t()
  def local_date(%DateTime{} = instant, value), do: instant |> shift(value) |> DateTime.to_date()

  defp resolve_wall({:ok, datetime}), do: {:ok, datetime}
  # Clocks went back: the wall time happened twice. Take the first.
  defp resolve_wall({:ambiguous, first, _second}), do: {:ok, first}
  # Clocks went forward: the wall time never existed. Take the instant the
  # clocks jumped to, rather than refusing a time someone plausibly meant.
  defp resolve_wall({:gap, _just_before, just_after}), do: {:ok, just_after}
  defp resolve_wall(_other), do: :error

  # Current offset of `id` in seconds, 0 if the database cannot place it.
  # Named apart from the public `offset_seconds/2`: same job, opposite argument
  # order, and two clauses of one name would just be a trap.
  defp zone_offset_at(%DateTime{} = now, id) do
    case DateTime.shift_zone(now, id, @database) do
      {:ok, shifted} -> shifted.utc_offset + shifted.std_offset
      {:error, _reason} -> 0
    end
  end

  # Accepts "2", "+2", "-5", "5.5" — the shapes the pre-IANA picker wrote.
  # Float.parse over Integer.parse is the half-hour fix: Integer.parse("5.5")
  # leaves ".5", which the old guard rejected into a no-op.
  defp parse_offset("+" <> rest), do: parse_offset(rest)

  defp parse_offset(value) when is_binary(value) do
    case Float.parse(value) do
      {hours, ""} when hours >= -12.0 and hours <= 14.0 -> {:ok, hours}
      _ -> :error
    end
  end

  defp parse_offset(_), do: :error

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(div(seconds, 60))
    hours = total |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{hours}:#{minutes}"
  end
end
