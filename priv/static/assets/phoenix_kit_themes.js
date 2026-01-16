/**
 * PhoenixKit Theme System
 * Handles theme switching with localStorage persistence and system theme detection
 */

(function() {
  'use strict';

  const THEME_STORAGE_KEY = 'phoenix_kit_theme';
  const SYSTEM_THEME = 'system';
  const LIGHT_THEME = 'phoenix-light';
  const DARK_THEME = 'phoenix-dark';

  /**
   * Get the preferred system theme
   */
  function getSystemTheme() {
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      return DARK_THEME;
    }
    return LIGHT_THEME;
  }

  /**
   * Apply theme to document
   */
  function applyTheme(theme) {
    const html = document.documentElement;

    if (theme === SYSTEM_THEME) {
      const systemTheme = getSystemTheme();
      html.setAttribute('data-theme', systemTheme);
    } else {
      html.setAttribute('data-theme', theme);
    }
  }

  /**
   * Save theme to localStorage
   */
  function saveTheme(theme) {
    try {
      localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch (e) {
      console.warn('PhoenixKit: Could not save theme to localStorage:', e);
    }
  }

  /**
   * Load theme from localStorage
   */
  function loadTheme() {
    try {
      return localStorage.getItem(THEME_STORAGE_KEY) || SYSTEM_THEME;
    } catch (e) {
      console.warn('PhoenixKit: Could not load theme from localStorage:', e);
      return SYSTEM_THEME;
    }
  }

  /**
   * Set theme and save it
   */
  function setTheme(theme) {
    applyTheme(theme);
    saveTheme(theme);
  }

  /**
   * Initialize theme system
   */
  function initializeTheme() {
    const savedTheme = loadTheme();
    applyTheme(savedTheme);

    // Listen for system theme changes
    if (window.matchMedia) {
      const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
      mediaQuery.addEventListener('change', function() {
        const currentTheme = loadTheme();
        if (currentTheme === SYSTEM_THEME) {
          applyTheme(SYSTEM_THEME);
        }
      });
    }
  }

  /**
   * Handle Phoenix theme change events
   */
  function handlePhoenixThemeChange(event) {
    const theme = event.detail.theme;
    if (theme && typeof theme === 'string') {
      setTheme(theme);

      // Close dropdowns after theme selection
      const dropdowns = document.querySelectorAll('[tabindex="0"]');
      dropdowns.forEach(function(dropdown) {
        if (dropdown.classList.contains('dropdown')) {
          dropdown.blur();
        }
      });
    }
  }

  // Initialize when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeTheme);
  } else {
    initializeTheme();
  }

  // Listen for Phoenix theme change events
  window.addEventListener('phx:set-theme', handlePhoenixThemeChange);

  // Expose theme functions for external use
  window.PhoenixKitTheme = {
    setTheme: setTheme,
    getTheme: loadTheme,
    getSystemTheme: getSystemTheme,
    applyTheme: applyTheme
  };

})();