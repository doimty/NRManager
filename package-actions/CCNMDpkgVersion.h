#ifndef CCNM_DPKG_VERSION_H
#define CCNM_DPKG_VERSION_H

#include <stdbool.h>

// Conservative, fail-closed subset of dpkg version ordering.
//
// dpkg passes the peer package version to prerm/postinst, and `upgrade` is used
// for downgrades too, so the maintainer scripts must be able to tell "the
// incoming build still has the restore implementation" from "the incoming build
// predates it". Implementing full dpkg ordering here would be unjustified: the
// only question asked is whether a version reaches a known floor.
//
// Contract: returns true only when `version` can be *proven* to be greater than
// or equal to `floorVersion`. Anything the comparison does not fully understand
// (an epoch, a non-numeric upstream component, an empty component, a NULL or
// empty string) returns false, which routes the caller to its safe path.
//
// `floorVersion` must be a plain dotted-numeric string such as "1.5.0".
bool CCNMDpkgVersionIsAtLeast(const char *version, const char *floorVersion);

#endif
