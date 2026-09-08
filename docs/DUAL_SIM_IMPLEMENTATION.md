# Dual-SIM Independent Configuration Implementation

## Overview
This implementation adds per-subscription configuration support to NR Manager, allowing each SIM card to maintain independent frequency band settings. When users switch the data line between SIM cards, the corresponding configuration is automatically loaded.

## Changes Made

### 1. UUID-based Configuration Paths
Added new functions to generate per-UUID file paths:
- `CCNMN78PolicyStatePathForUUID(NSString *uuid)`
- `CCNMN78PolicyBaselinePathForUUID(NSString *uuid)`
- `CCNMN78PolicyIntentPathForUUID(NSString *uuid)`
- `CCNMN78PolicyInFlightPathForUUID(NSString *uuid)`
- `CCNMN78PolicyLockPathForUUID(NSString *uuid)`

File naming format: `com.doimty.nrmanager.n78-policy.<normalized_uuid>.state.plist`

### 2. UUID Management
- `CCNMNormalizeUUID(NSString *uuid)`: Normalizes UUID to lowercase without dashes for safe filenames
- `CCNMGetActiveSubscriptionUUID()`: Retrieves current data line UUID using CoreTelephony

### 3. Legacy Compatibility Layer
Modified existing path functions to automatically use UUID-based paths:
- `CCNMN78PolicyStatePath()` → `CCNMN78PolicyStatePathForUUID(currentUUID)`
- Falls back to legacy paths if UUID cannot be determined

### 4. Configuration Migration
Added `CCNMMigrateLegacyConfigToUUIDIfNeeded()`:
- Runs once on first read after upgrade
- Renames legacy files (without UUID) to current UUID format
- Preserves existing configurations for current SIM card
- Uses atomic `rename()` operations with directory sync

### 5. Read Path Integration
Modified `CCNMReadPolicyStateInternal()` to invoke migration before reading configuration.

## Technical Details

### File Naming
- **Old format**: `n78-policy.state.plist`
- **New format**: `n78-policy.a1b2c3d4e5f6.state.plist` (UUID normalized to lowercase hex)

### UUID Validation
The existing UUID validation logic at lines 1134, 1201, and 1393 requires NO modification because:
- Configuration files are now read based on current UUID
- `state`, `baseline`, and `intent` naturally come from the same UUID's files
- Validation checks naturally pass when all records match the current UUID

### Migration Strategy
1. Check for legacy files existence
2. Get current data line UUID
3. Skip if UUID-based config already exists
4. Rename each legacy file to UUID-based name
5. Sync parent directory for durability

## User Experience

### Single-SIM Users
- Seamless upgrade: legacy config automatically migrated to current UUID
- No user action required
- Settings preserved

### Dual-SIM Users
#### Scenario A: Same SIM Card
1. User enables n78 lock on SIM 1
2. Switches data line to SIM 2 (first time)
3. NR Manager shows default state (no config for SIM 2 yet)
4. User can configure SIM 2 independently
5. Switches back to SIM 1: **n78 lock is restored** ✓

#### Scenario B: Replace SIM Card
1. User has n78 lock on SIM 1
2. Removes SIM 1, inserts new SIM 3
3. New UUID detected → fresh configuration state
4. Previous settings not applied (safe) ✓

### Edge Cases Handled
- **No SIM inserted**: Falls back to legacy paths
- **UUID fetch fails**: Falls back to legacy paths
- **eSIM re-add**: Treated as new SIM (new UUID)
- **3+ SIM cards**: Fully supported (dynamic UUID-based routing)

## Testing Checklist

### Regression Testing
- [ ] Single-SIM user upgrades: config preserved
- [ ] Enable → disable → re-enable works
- [ ] Boot persistence verified

### Dual-SIM Scenarios
- [ ] SIM1 enable → switch to SIM2 → SIM2 enable → switch back to SIM1 (settings preserved)
- [ ] SIM1 enable → remove SIM1 → insert new SIM3 (fresh state, no incorrect bands)
- [ ] Rapid data line switching (stress test)
- [ ] Switch during active enable operation

### Edge Cases
- [ ] No SIM inserted
- [ ] Airplane mode
- [ ] eSIM deletion and re-addition
- [ ] 3+ SIM cards (if testable)

## Implementation Statistics
- **Lines added**: ~142
- **Functions added**: 8
- **Functions modified**: 6
- **Files changed**: 1 (`CCNMN78PolicyController.m`)

## Future Enhancements (Optional)
1. UI to display "Current card: SIM 1" / "Current card: SIM 2"
2. Configuration list showing all configured SIM cards
3. "Copy configuration to another SIM" feature
4. "Apply same configuration to all SIMs" option

## Rollback Plan
If issues arise, revert the single commit containing these changes. Legacy users will continue to use single-config mode. Dual-SIM users may need to reconfigure after rollback.
