defmodule PhoenixKit.Utils.HeroIcons do
  @moduledoc """
  Curated list of Heroicons for use in the application.
  Icons are grouped by category for easy browsing.
  """

  @doc """
  Returns all available icons grouped by category.
  """
  def list_icons_by_category do
    %{
      "General" => [
        {"hero-cube", "Cube"},
        {"hero-squares-2x2", "Grid"},
        {"hero-square-3-stack-3d", "Stack"},
        {"hero-cube-transparent", "Cube Transparent"},
        {"hero-archive-box", "Archive Box"},
        {"hero-inbox", "Inbox"},
        {"hero-folder", "Folder"},
        {"hero-folder-open", "Folder Open"},
        {"hero-document", "Document"},
        {"hero-document-text", "Document Text"},
        {"hero-clipboard", "Clipboard"},
        {"hero-bookmark", "Bookmark"}
      ],
      "Content" => [
        {"hero-document-duplicate", "Documents"},
        {"hero-newspaper", "Newspaper"},
        {"hero-book-open", "Book"},
        {"hero-academic-cap", "Academic"},
        {"hero-photo", "Photo"},
        {"hero-film", "Film"},
        {"hero-musical-note", "Music"},
        {"hero-microphone", "Microphone"},
        {"hero-speaker-wave", "Speaker"},
        {"hero-video-camera", "Video"}
      ],
      "Actions" => [
        {"hero-plus", "Plus"},
        {"hero-minus", "Minus"},
        {"hero-pencil", "Pencil"},
        {"hero-trash", "Trash"},
        {"hero-check", "Check"},
        {"hero-check-circle", "Check Circle"},
        {"hero-x-mark", "X Mark"},
        {"hero-arrow-path", "Refresh"},
        {"hero-arrow-down-tray", "Download"},
        {"hero-arrow-up-tray", "Upload"},
        {"hero-magnifying-glass", "Search"},
        {"hero-funnel", "Filter"}
      ],
      "Navigation" => [
        {"hero-home", "Home"},
        {"hero-arrow-right", "Arrow Right"},
        {"hero-arrow-left", "Arrow Left"},
        {"hero-arrow-up", "Arrow Up"},
        {"hero-arrow-down", "Arrow Down"},
        {"hero-chevron-right", "Chevron Right"},
        {"hero-chevron-left", "Chevron Left"},
        {"hero-chevron-up", "Chevron Up"},
        {"hero-chevron-down", "Chevron Down"},
        {"hero-bars-3", "Menu"}
      ],
      "Communication" => [
        {"hero-envelope", "Email"},
        {"hero-chat-bubble-left", "Chat"},
        {"hero-bell", "Bell"},
        {"hero-megaphone", "Megaphone"},
        {"hero-phone", "Phone"},
        {"hero-paper-airplane", "Send"},
        {"hero-at-symbol", "At Symbol"}
      ],
      "Users" => [
        {"hero-user", "User"},
        {"hero-user-group", "User Group"},
        {"hero-user-circle", "User Circle"},
        {"hero-users", "Users"},
        {"hero-identification", "ID Card"},
        {"hero-shield-check", "Shield"}
      ],
      "Business" => [
        {"hero-briefcase", "Briefcase"},
        {"hero-building-office", "Office"},
        {"hero-building-storefront", "Store"},
        {"hero-shopping-cart", "Cart"},
        {"hero-shopping-bag", "Shopping Bag"},
        {"hero-currency-dollar", "Dollar"},
        {"hero-credit-card", "Credit Card"},
        {"hero-chart-bar", "Chart"},
        {"hero-presentation-chart-line", "Presentation"}
      ],
      "Interface" => [
        {"hero-cog-6-tooth", "Settings"},
        {"hero-adjustments-horizontal", "Adjustments"},
        {"hero-lock-closed", "Lock"},
        {"hero-lock-open", "Unlock"},
        {"hero-key", "Key"},
        {"hero-eye", "Eye"},
        {"hero-eye-slash", "Eye Slash"},
        {"hero-star", "Star"},
        {"hero-heart", "Heart"},
        {"hero-flag", "Flag"}
      ],
      "Tech" => [
        {"hero-code-bracket", "Code"},
        {"hero-command-line", "Terminal"},
        {"hero-computer-desktop", "Desktop"},
        {"hero-device-phone-mobile", "Mobile"},
        {"hero-server", "Server"},
        {"hero-cloud", "Cloud"},
        {"hero-link", "Link"},
        {"hero-wifi", "WiFi"},
        {"hero-signal", "Signal"},
        {"hero-bolt", "Bolt"}
      ],
      "Status" => [
        {"hero-information-circle", "Info"},
        {"hero-exclamation-triangle", "Warning"},
        {"hero-exclamation-circle", "Exclamation"},
        {"hero-question-mark-circle", "Question"},
        {"hero-light-bulb", "Idea"},
        {"hero-sparkles", "Sparkles"},
        {"hero-fire", "Fire"}
      ]
    }
  end

  @doc """
  Returns a flat list of all available icons.
  """
  def list_all_icons do
    list_icons_by_category()
    |> Enum.flat_map(fn {_category, icons} -> icons end)
  end

  @doc """
  Returns all category names.
  """
  def list_categories do
    list_icons_by_category()
    |> Map.keys()
  end

  @doc """
  Searches for icons by name or display name.
  """
  def search_icons(query) when is_binary(query) do
    query_lower = String.downcase(query)

    list_all_icons()
    |> Enum.filter(fn {icon_name, display_name} ->
      String.contains?(String.downcase(icon_name), query_lower) ||
        String.contains?(String.downcase(display_name), query_lower)
    end)
  end
end
