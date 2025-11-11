# PhoenixKit Referral Codes System - Technical Specification

## Overview

The PhoenixKit Referral Codes System provides a comprehensive referral code management solution with toggleable features, usage tracking, and integration with the PhoenixKit authentication system. This module enables administrators to create, manage, and track referral codes while providing flexible configuration options for user registration workflows.

## Architecture

### Module Structure
```
lib/phoenix_kit/
├── referral_codes.ex                    # Main business logic module
└── referral_code_usage.ex               # Usage tracking module

lib/phoenix_kit_web/live/referral_codes/
├── referral_codes_live.ex               # Admin interface LiveView
├── referral_codes_live.html.heex        # Admin interface template
└── SPEC.pm                             # This technical specification
```

### Database Schema

#### phoenix_kit_referral_codes
| Field           | Type         | Description                                      |
|-----------------|--------------|--------------------------------------------------|
| id              | bigint       | Primary key                                      |
| code            | string       | Unique referral code (3-50 chars)                |
| description     | string       | Human-readable description (1-255 chars)         |
| status          | boolean      | Active/inactive status (default: true)           |
| number_of_uses  | integer      | Current usage count (default: 0)                 |
| max_uses        | integer      | Maximum allowed uses (must be > 0)               |
| created_by      | integer      | User ID of creator                               |
| beneficiary     | integer      | User ID who benefits from code usage (optional)  |
| date_created    | utc_datetime | Creation timestamp                               |
| expiration_date | utc_datetime | Expiration timestamp                             |

#### phoenix_kit_referral_code_usage
| Field     | Type         | Description                        |
|-----------|--------------|------------------------------------|
| id        | bigint       | Primary key                        |
| code_id   | bigint       | Foreign key to referral_codes      |
| used_by   | integer      | User ID who used the code          |
| date_used | utc_datetime | Usage timestamp                    |

## Configuration

### Settings Integration
The configuration integrates with PhoenixKit Settings module using:
- **Module**: `"referral_codes"`
- **Key**: `"referral_codes_enabled"` - Enable/disable toggle (boolean)
- **Key**: `"referral_codes_required"` - Registration requirement toggle (boolean)

### Default Values
- **Default Expiration**: 7 days from creation date
- **Default Max Uses**: 100 uses per code
- **Default Status**: Active (true)
- **Code Generation**: 5-character alphanumeric (excludes 0, O, I, 1)

## Core Functionality

### 1. System Toggle
The referral system appears as a toggleable feature in the Modules page:
- **Toggle Setting**: `referral_codes_enabled` (boolean)
- **Default State**: Disabled (false)
- **Effect**: Controls system-wide availability

### 2. Registration Requirement
Sub-toggle within the referral system:
- **Setting**: `referral_codes_required` (boolean)
- **Default State**: Optional (false)
- **Effect**: When enabled, users must provide valid referral code during registration

### 3. Code Management

#### Code Generation
Two methods for code creation:
1. **Random Generation**: Automatic 5-character alphanumeric codes
2. **Custom Input**: Manual code entry by administrator

#### Code Validation
- **Uniqueness**: Codes must be unique across system
- **Format**: 3-50 characters, alphanumeric preferred
- **Expiration**: Must be future-dated if specified
- **Usage Limits**: Maximum uses must be positive integer

#### Code Lifecycle
1. **Creation**: Admin creates code with parameters
2. **Active Period**: Code can be used while valid
3. **Usage Tracking**: Each use increments counter and creates usage record
4. **Expiration**: Codes become invalid after expiration date or max uses reached

### 4. Usage Tracking
- **Atomic Operations**: Usage counting and record creation in transaction
- **Audit Trail**: Complete record of who used what code when
- **Statistics**: Usage analytics and reporting

### 5. Beneficiary System
The beneficiary system allows administrators to designate which user should receive benefits when specific referral codes are used:

#### Beneficiary Assignment
- **Optional Field**: Beneficiary assignment is optional for all codes
- **User Selection**: Administrators can select from all registered users via dropdown
- **Storage**: Beneficiary is stored as integer user ID in database
- **Display**: Dashboard displays beneficiary email address for easy identification

#### Use Cases
- **Reward Programs**: Assign codes to specific users for tracking their referral success
- **Partner Programs**: Track referrals generated by business partners or affiliates
- **Employee Programs**: Monitor referrals from staff members or contractors
- **Influencer Programs**: Attribute referrals to content creators or social media influencers

#### Data Flow
1. Administrator selects beneficiary user during code creation/editing
2. User ID is saved to `beneficiary` field as integer
3. Dashboard loads user relationship and displays email address
4. Beneficiary information available for analytics and reporting

## User Interface

### Admin Interface (LiveView)
Located at: `{prefix}/admin/users/referral-codes`

Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`)

#### Features:
- **Code List**: Table view of all codes with status indicators and beneficiary information
- **Create Code**: Form with code generation options and beneficiary selection
- **Edit Code**: Modify existing code parameters including beneficiary assignment
- **Delete Code**: Remove codes from system
- **Toggle Status**: Activate/deactivate individual codes
- **Beneficiary Management**: Assign and display user beneficiaries for each code
- **Statistics Dashboard**: System-wide usage metrics
- **Code Validation**: Real-time form validation with examples

#### Status Indicators:
- **Active**: Green badge - code is valid and usable
- **Inactive**: Gray badge - code is disabled
- **Expired**: Red badge - code has passed expiration
- **Limit Reached**: Yellow badge - code has hit max uses

### Registration Integration
Integration points in user registration:
- **Optional Mode**: Referral code field shown but not required
- **Required Mode**: Registration blocked without valid referral code
- **Validation**: Real-time code validation during form submission
- **Error Messages**: Clear feedback for invalid/expired codes

## API Reference

### Main Module Functions

#### Code Management
```elixir
# List all codes
PhoenixKit.ReferralCodes.list_codes()

# Get code by ID
PhoenixKit.ReferralCodes.get_code!(id)

# Get code by string
PhoenixKit.ReferralCodes.get_code_by_string("CODE123")

# Create new code
PhoenixKit.ReferralCodes.create_code(attrs)

# Update existing code
PhoenixKit.ReferralCodes.update_code(code, attrs)

# Delete code
PhoenixKit.ReferralCodes.delete_code(code)

# Generate random code
PhoenixKit.ReferralCodes.generate_random_code()
```

#### Code Validation
```elixir
# Check if code is valid for use
PhoenixKit.ReferralCodes.valid_for_use?(code)

# Check if code is expired
PhoenixKit.ReferralCodes.expired?(code)

# Check if usage limit reached
PhoenixKit.ReferralCodes.usage_limit_reached?(code)
```

#### Usage Tracking
```elixir
# Record code usage
PhoenixKit.ReferralCodes.use_code("CODE123", user_id)

# Get usage statistics
PhoenixKit.ReferralCodes.get_usage_stats(code_id)

# List usage for code
PhoenixKit.ReferralCodes.list_usage_for_code(code_id)

# Check if user used code
PhoenixKit.ReferralCodes.user_used_code?(user_id, code_id)
```

#### System Settings
```elixir
# Check if system enabled
PhoenixKit.ReferralCodes.enabled?()

# Check if required for registration
PhoenixKit.ReferralCodes.required?()

# Enable/disable system
PhoenixKit.ReferralCodes.enable_system()
PhoenixKit.ReferralCodes.disable_system()

# Set requirement status
PhoenixKit.ReferralCodes.set_required(true)

# Get system configuration
PhoenixKit.ReferralCodes.get_config()

# List valid codes
PhoenixKit.ReferralCodes.list_valid_codes()

# Get system statistics
PhoenixKit.ReferralCodes.get_system_stats()
```

## Security Considerations

### Code Generation
- **Excludes Confusing Characters**: 0, O, I, 1 excluded to prevent confusion
- **Random Generation**: Cryptographically secure random selection
- **Length Validation**: Minimum 3 characters for usability

### Usage Validation
- **Transaction Safety**: Usage counting wrapped in database transactions
- **Race Condition Protection**: Prevents concurrent usage counting issues
- **User Validation**: Ensures codes can't be reused by same user

### Access Control
- **Admin Only**: Code creation/management restricted to administrators
- **Settings Integration**: Leverages PhoenixKit's existing authorization
- **Audit Trail**: Complete usage tracking for security analysis

## Performance Considerations

### Database Optimization
- **Indexed Fields**: `code`, `status`, `expiration_date` indexed for queries
- **Efficient Queries**: Optimized for large code sets with proper filtering
- **Transaction Boundaries**: Minimal transaction scopes to reduce locking

### Caching Strategy
- **Status**: Settings cached via PhoenixKit Settings module
- **Code Validation**: Individual code lookups optimized with get_by queries
- **Statistics**: Aggregated stats calculated on-demand with efficient queries

## Error Handling

### Validation Errors
- **Code Uniqueness**: Prevents duplicate codes with clear error messages
- **Format Validation**: Enforces character limits and content rules
- **Date Validation**: Ensures expiration dates are in the future
- **Usage Limits**: Validates positive integer requirements

### Runtime Errors
- **Code Not Found**: Graceful handling of invalid codes
- **Expired Codes**: Clear messaging for time-based restrictions
- **Usage Limits**: Informative feedback when limits reached
- **System Disabled**: Appropriate messaging when feature disabled

## Integration Points

### PhoenixKit Settings
- **Module Integration**: Settings stored with module: `"referral_codes"`
- **Boolean Settings**: All toggle settings use proper boolean values
- **Default Values**: Sensible defaults for all configuration options

### Authentication System
- **Registration Hook**: Integrates with PhoenixKit registration flow
- **User Context**: Leverages existing user management
- **Session Management**: Works with PhoenixKit session handling

### Admin Dashboard
- **Module Toggle**: Appears in Modules page with sub-navigation
- **Statistics Integration**: Usage metrics integrated with dashboard
- **Consistent UI**: Follows PhoenixKit admin interface patterns

## Future Enhancements

### Planned Features
- **Bulk Code Generation**: Create multiple codes at once
- **Code Categories**: Organize codes by type or campaign
- **Advanced Analytics**: Detailed usage reporting and trends
- **Email Integration**: Automated code distribution capabilities
- **API Endpoints**: RESTful API for external integrations

### Scalability Considerations
- **Partitioning Support**: Ready for large-scale usage partitioning
- **Background Jobs**: Async processing for bulk operations
- **Caching Layer**: Redis integration for high-traffic scenarios

## Testing Strategy

### Unit Tests
- **Schema Validation**: Comprehensive changeset testing
- **Business Logic**: All core functions individually tested
- **Edge Cases**: Boundary conditions and error scenarios

### Integration Tests
- **Registration Flow**: End-to-end registration with codes
- **Admin Interface**: Complete admin workflow testing
- **Settings Integration**: Settings module interaction testing

### Performance Tests
- **Code Generation**: Random generation performance
- **Usage Tracking**: Concurrent usage validation
- **Large Dataset**: Performance with high code volumes

---

**Document Version**: 1.0  
**Last Updated**: September 2025  
**Maintainer**: PhoenixKit Development Team

---

## Appendix: Complete API Function Signatures

### Schema Functions
```elixir
@spec changeset(t(), map()) :: Ecto.Changeset.t()
def changeset(referral_code, attrs)

@spec generate_random_code() :: String.t()
def generate_random_code()

@spec valid_for_use?(t()) :: boolean()
def valid_for_use?(code)

@spec expired?(t()) :: boolean()
def expired?(code)

@spec usage_limit_reached?(t()) :: boolean()
def usage_limit_reached?(code)
```

### Business Logic Functions
```elixir
@spec list_codes() :: [t()]
def list_codes()

@spec get_code!(integer()) :: t() | no_return()
def get_code!(id)

@spec get_code_by_string(String.t()) :: t() | nil
def get_code_by_string(code_string)

@spec create_code(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
def create_code(attrs \\ %{})

@spec update_code(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
def update_code(referral_code, attrs)

@spec delete_code(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
def delete_code(referral_code)

@spec change_code(t(), map()) :: Ecto.Changeset.t()
def change_code(referral_code, attrs \\ %{})
```

### Usage Tracking Functions
```elixir
@spec use_code(String.t(), integer()) :: {:ok, ReferralCodeUsage.t()} | {:error, atom()}
def use_code(code_string, user_id)

@spec get_usage_stats(integer()) :: map()
def get_usage_stats(code_id)

@spec list_usage_for_code(integer()) :: [ReferralCodeUsage.t()]
def list_usage_for_code(code_id)

@spec user_used_code?(integer(), integer()) :: boolean()
def user_used_code?(user_id, code_id)
```

### System Settings Functions
```elixir
@spec enabled?() :: boolean()
def enabled?()

@spec required?() :: boolean()
def required?()

@spec enable_system() :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
def enable_system()

@spec disable_system() :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
def disable_system()

@spec set_required(boolean()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
def set_required(required)

@spec get_config() :: %{enabled: boolean(), required: boolean()}
def get_config()

@spec list_valid_codes() :: [t()]
def list_valid_codes()

@spec get_system_stats() :: %{
  total_codes: integer(),
  active_codes: integer(),
  total_usage: integer(),
  codes_with_usage: integer()
}
def get_system_stats()
```

## Database Indexes

### Primary Indexes
```sql
-- Primary keys (automatically created)
CREATE INDEX idx_referral_codes_pkey ON phoenix_kit_referral_codes (id);
CREATE INDEX idx_referral_code_usage_pkey ON phoenix_kit_referral_code_usage (id);

-- Unique constraints
CREATE UNIQUE INDEX idx_referral_codes_code ON phoenix_kit_referral_codes (code);
```

### Performance Indexes
```sql
-- Query optimization indexes
CREATE INDEX idx_referral_codes_status ON phoenix_kit_referral_codes (status);
CREATE INDEX idx_referral_codes_expiration ON phoenix_kit_referral_codes (expiration_date);
CREATE INDEX idx_referral_codes_created_by ON phoenix_kit_referral_codes (created_by);
CREATE INDEX idx_referral_code_usage_code_id ON phoenix_kit_referral_code_usage (code_id);
CREATE INDEX idx_referral_code_usage_used_by ON phoenix_kit_referral_code_usage (used_by);
CREATE INDEX idx_referral_code_usage_date_used ON phoenix_kit_referral_code_usage (date_used);
```

## Deployment Checklist

### Pre-deployment
- [ ] Database migrations applied
- [ ] Settings module configured
- [ ] Admin permissions configured
- [ ] Email templates reviewed (if applicable)

### Post-deployment
- [ ] System toggle tested
- [ ] Registration requirement toggle tested
- [ ] Code creation workflow verified
- [ ] Usage tracking validated
- [ ] Statistics dashboard functional
- [ ] Error handling verified

### Monitoring
- [ ] Usage statistics tracking enabled
- [ ] Error logging configured
- [ ] Performance metrics monitored
- [ ] Security audit trail active

---

**Document Version**: 1.0  
**Last Updated**: September 2025  
**Maintainer**: PhoenixKit Development Team  
**Status**: Production Ready**Document Version**: 1.0  
**Last Updated**: September 2025  
**Maintainer**: PhoenixKit Development Team  
**Status**: Production Ready