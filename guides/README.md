# PhoenixKit Development Guides

This folder contains comprehensive guides to help developers work with PhoenixKit features and patterns.

## For External Users (Using PhoenixKit as a Dependency)

### [Integration Guide](integration.md) ⭐ Start Here

**The essential guide for developers using PhoenixKit as a Hex dependency.** Covers:
- Quick start installation
- Configuration reference
- Authentication integration
- Troubleshooting common issues
- Links to feature-specific guides

**This guide is optimized for AI assistants** (Claude, Cursor, Copilot, Tidewave MCP) to help you integrate PhoenixKit into your Phoenix application.

---

## Available Guides

### Core Guides

#### [Custom Admin Pages](custom-admin-pages.md)

**Add custom pages to the PhoenixKit admin sidebar.** Learn how to:
- Create LiveViews that integrate with PhoenixKit's admin layout
- Register tabs in the admin navigation
- Configure permission gates
- Use seamless LiveView navigation
- Implement common patterns (pagination, events, etc.)

**Use this guide when:**
- Adding custom admin pages to your application
- Extending the PhoenixKit admin interface
- Building admin functionality for your features

#### [Your App as a Module](your-app-as-a-module.md)

**Use PhoenixKit's module hooks from your own application.** Clean up after a
deleted account (`before_user_delete/1`), declare notification types, schedule
Oban jobs, protect stored files from the orphan check, add profile settings
tabs. A host can implement `PhoenixKit.Module` itself and is discovered like
any other module.

#### [Locale Routing](locale-routing.md)

**Why the language of a page lives in its URL, and how to migrate an app that
kept it in the session.** Read this when the language switcher's links don't
behave, or before building a multilingual site on PhoenixKit.

#### [Customizing Emails with Template Files](email-templates.md)

**Override the copy of PhoenixKit's emails, and the HTML layout every email is
wrapped in, with files in your application's `priv/`.** Covers where the files
go, per-locale variants, the `_layout` override and its variables, and sending
one email without the layout.

### Feature Guides

#### [Making Pages Live: Real-time Updates & Collaborative Editing](making-pages-live.md)

Learn how to add real-time functionality to LiveView pages, including:
- PubSub event broadcasting
- Presence tracking for collaborative editing
- Temporary state storage with auto-expiration
- On-mount hooks for centralized subscriptions
- Common patterns and troubleshooting

**Use this guide when:**
- Adding real-time updates to list pages
- Implementing collaborative form editing
- Building live dashboards or detail pages
- Setting up presence tracking for any resource

#### [OAuth & Magic Link Setup](oauth-and-magic-link-setup.md)

Configure OAuth providers and magic link authentication for PhoenixKit.

#### [AWS Email Setup](aws-email-setup.md)

Set up AWS SES for email infrastructure automation.

#### [Auth Header Integration](auth-header-integration.md)

Authentication header patterns for PhoenixKit.

#### [PHK Publishing Format](phk-publishing-format.md)

Understanding the .phk publishing file format.

#### [Draggable List Component](draggable-list-component.md)

Using the draggable list component for sortable UIs.

#### [Per-Module i18n with Gettext](per-module-i18n.md)

Translate sidebar tab labels, group labels, and tooltips inside your PhoenixKit module. Each module ships its own Gettext backend and `.po` files; tabs render localized labels at request time. Required for every module that exposes UI on `phoenix_kit ~> 1.8`.

#### [Upgrading to PhoenixKit 3.0](upgrading-to-3.0.md)

For an install coming from 2.x: reach V225 on 2.65.0 first, export edited email templates, then update core and every installed module together.

#### [Public and Admin JavaScript](public-and-admin-javascript.md)

Why `phoenix_kit.js` is only the public half, how `phoenix_kit_admin.js` loads on the first admin hook, and what a host or a module has to do (nothing, for most installs).

---

## Guide Purpose

These guides are designed to:
1. **Speed up development** - Provide working examples and patterns
2. **Maintain consistency** - Establish conventions across the codebase
3. **Reduce errors** - Document common pitfalls and solutions
4. **Help AI assistants** - Give clear context for code generation
5. **Onboard new developers** - Comprehensive documentation of systems

## Using These Guides

### For Developers

1. Read the relevant guide before implementing a feature
2. Copy and adapt the patterns to your use case
3. Reference the example files mentioned in each guide
4. Follow the best practices section
5. Check troubleshooting if you encounter issues

### For AI Assistants (Claude, etc.)

These guides provide the context needed to generate accurate code:
- System architecture and locations
- Established patterns and conventions
- Working examples from the codebase
- Common pitfalls to avoid

When asked to implement a feature, reference the appropriate guide to understand the existing infrastructure and patterns.

## Contributing New Guides

When adding a new guide:

1. **Focus on patterns** - Show how systems work together
2. **Provide examples** - Include working code from the codebase
3. **Reference real files** - Point to actual implementations
4. **Include troubleshooting** - Document common issues
5. **Keep it practical** - Focus on "how to" not just "what is"

### Guide Template

```markdown
# [Feature Name]: [Brief Description]

## Table of Contents
- Overview
- Quick Start
- Detailed Explanation
- Common Patterns
- Troubleshooting
- Best Practices
- Reference Files

## Overview
Brief explanation of the system and its purpose.

## Quick Start
Minimal working example to get started quickly.

## Detailed Explanation
Deep dive into how the system works.

## Common Patterns
Real examples from the codebase.

## Troubleshooting
Common issues and solutions.

## Best Practices
Conventions and recommendations.

## Reference Files
Links to actual implementation files.
```

## Planned Guides

Future guides to add:
- **Testing LiveView Pages** - Patterns for testing real-time features
- **Database Migrations** - PhoenixKit's versioned migration system
- **UI Components** - Creating reusable Phoenix components
- **Machine API** - Keys, tools, REST and MCP (today: Settings → API → guide, in the admin)

## Completed Guides

- ✅ **Integration Guide** - Core installation and configuration
- ✅ **Custom Admin Pages** - Admin sidebar integration
- ✅ **Making Pages Live** - Real-time updates and collaborative editing
- ✅ **OAuth & Magic Link Setup** - Authentication providers
- ✅ **AWS Email Setup** - Email infrastructure automation
- ✅ **Auth Header Integration** - Authentication header patterns
- ✅ **Your App as a Module** - PhoenixKit's module hooks from your own application
- ✅ **Locale Routing** - The language in the URL
- ✅ **Customizing Emails with Template Files** - Override any email, per language
- ✅ **Per-Module i18n with Gettext** - Translations of a module package
- ✅ **Upgrading to PhoenixKit 3.0** - For installs coming from 2.x

## Feedback

If you find issues or have suggestions for these guides, please update them directly or document the issue for future improvement.
