defmodule PhoenixKitWeb.Routes.ReferralsRoutes do
  @moduledoc """
  Referral codes module routes.

  Provides route definitions for referral code settings and management.
  """

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
  def admin_locale_routes do
    quote do
      live "/admin/settings/referral-codes",
           PhoenixKit.Modules.Referrals.Web.Settings,
           :index,
           as: :referral_codes_settings_localized

      live "/admin/users/referral-codes", PhoenixKit.Modules.Referrals.Web.List, :index,
        as: :referral_codes_list_localized

      live "/admin/users/referral-codes/new", PhoenixKit.Modules.Referrals.Web.Form, :new,
        as: :referral_codes_new_localized

      live "/admin/users/referral-codes/edit/:code_id",
           PhoenixKit.Modules.Referrals.Web.Form,
           :edit,
           as: :referral_codes_edit_localized
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  def admin_routes do
    quote do
      live "/admin/settings/referral-codes",
           PhoenixKit.Modules.Referrals.Web.Settings,
           :index,
           as: :referral_codes_settings

      live "/admin/users/referral-codes", PhoenixKit.Modules.Referrals.Web.List, :index,
        as: :referral_codes_list

      live "/admin/users/referral-codes/new", PhoenixKit.Modules.Referrals.Web.Form, :new,
        as: :referral_codes_new

      live "/admin/users/referral-codes/edit/:code_id",
           PhoenixKit.Modules.Referrals.Web.Form,
           :edit,
           as: :referral_codes_edit
    end
  end
end
