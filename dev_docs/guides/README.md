# PhoenixKit Development Guides

This folder contains comprehensive guides to help developers work with PhoenixKit features and patterns.

## For External Users (Using PhoenixKit as a Dependency)

### [Integration Guide](2025-12-03-integration.md) ⭐ Start Here

**The essential guide for developers using PhoenixKit as a Hex dependency.** Covers:
- Quick start installation
- Configuration reference
- Using the Entities system
- Public forms for contact/lead capture
- Authentication integration
- API reference with examples
- Troubleshooting common issues

**This guide is optimized for AI assistants** (Claude, Cursor, Copilot, Tidewave MCP) to help you integrate PhoenixKit into your Phoenix application.

---

## Available Guides

### [Making Pages Live: Real-time Updates & Collaborative Editing](2025-10-09-making-pages-live.md)

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

### [Module System: Building PhoenixKit Modules](2026-02-24-module-system.md)

The complete guide to PhoenixKit's plugin architecture. Covers:
- How auto-discovery works (beam file scanning)
- All required and optional callbacks with examples
- Tab definitions (admin, settings, user dashboard)
- Permission metadata and role-based access
- Supervisor children and boot ordering
- Route integration for external packages
- Enable/disable patterns including cascades
- Critical pitfalls for developers and AI agents

**Use this guide when:**
- Building a new internal module
- Creating an external `phoenix_kit_*` hex package
- Debugging why a module tab is not appearing
- Understanding how the permission system connects to modules

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
- **Internationalization** - Multi-language support patterns

## Completed Guides

- ✅ **Integration Guide** - External user guide with API reference
- ✅ **Making Pages Live** - Real-time updates and collaborative editing
- ✅ **OAuth & Magic Link Setup** - Authentication providers
- ✅ **AWS Email Setup** - Email infrastructure automation
- ✅ **Auth Header Integration** - Authentication header patterns
- ✅ **Module System** - Building internal and external PhoenixKit modules

## Feedback

If you find issues or have suggestions for these guides, please update them directly or document the issue for future improvement.
