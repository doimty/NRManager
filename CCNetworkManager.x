// The formal bundle uses the same source as the verified standalone LiveCC
// module. Only the runtime class names are adapted to the package's principal
// class; the serving state machine remains a single source of truth.
#define NetworkManagerLiveViewController CCNetworkManagerViewController
#define NetworkManagerLiveModule CCNetworkManager
#import "livecc/Sources/NetworkManagerLiveModule.m"
