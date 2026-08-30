#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

NS_ASSUME_NONNULL_BEGIN

// The child pane that chooses which NR bands the policy should pin.
//
// It never writes to the modem. The only durable thing it touches is the pending
// selection preference, and only from the explicit save action; the modem write
// stays behind the switch on the parent pane, so there remains exactly one path
// that can change radio configuration.
//
// The pane is deliberately unavailable unless the policy is in a clean
// system-default state. That is not cosmetic caution: while the feature is on,
// the live active NR array *is* the applied selection, so the selectable domain
// read from a live capability sample would be the current selection rather than
// what the system originally allowed. Offering rows in that state would present a
// domain that silently shrinks with every apply.
@interface CCNMBandSelectionListController : PSListController

@end

NS_ASSUME_NONNULL_END
