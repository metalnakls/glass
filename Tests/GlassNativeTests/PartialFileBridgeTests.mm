#import "LocalTransmissionBridge.h"
#include <cassert>
#include <sys/stat.h>
#include <unistd.h>

static bool hidden(NSString *path) {
    struct stat st{}; assert(stat(path.fileSystemRepresentation, &st) == 0);
    return (st.st_flags & UF_HIDDEN) != 0;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSURL *root = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *config = [root URLByAppendingPathComponent:@"config"];
        NSURL *payload = [root URLByAppendingPathComponent:@"payload"];
        NSError *error = nil;
        LocalTransmissionBridge *bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:&error];
        assert(bridge && !error);
        NSData *metadata = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"test.torrent"]];
        assert([bridge addTorrentData:metadata downloadDirectory:payload.path startPaused:YES error:&error]);
        NSString *hash = [bridge snapshotWithError:&error][@"torrents"][0][@"hashString"];
        assert(([bridge setWanted:NO forTorrent:hash fileIndices:@[@0, @2] error:&error]));
        assert([bridge verifyTorrents:@[hash] error:&error]);
        NSDictionary *details = nil;
        for (int i = 0; i < 100; ++i) {
            usleep(100000);
            details = [bridge torrentDetailsForHash:hash error:&error];
            if ([details[@"percentDone"] doubleValue] == 1) { break; }
        }
        assert([details[@"percentDone"] doubleValue] == 1);
        assert(![details[@"fileStats"][0][@"wanted"] boolValue]);
        assert([details[@"fileStats"][1][@"wanted"] boolValue]);
        assert(![details[@"fileStats"][2][@"wanted"] boolValue]);
        NSString *left = [payload.path stringByAppendingPathComponent:@"Album/left.flac.part"];
        NSString *middle = [payload.path stringByAppendingPathComponent:@"Album/middle.flac"];
        NSString *right = [payload.path stringByAppendingPathComponent:@"Album/right.flac.part"];
        assert(hidden(left) && hidden(right) && !hidden(middle));
        NSString *collision = [payload.path stringByAppendingPathComponent:@"Existing"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:collision withIntermediateDirectories:YES attributes:nil error:&error]);
        error = nil;
        assert(![bridge renameTorrent:hash path:@"Album" name:@"Existing" error:&error]);
        assert(error != nil);
        NSDictionary *conflict = [bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"];
        assert([conflict[@"destination"] isEqual:collision]);
        assert([conflict[@"name"] isEqual:@"Existing"]);
        assert([conflict[@"token"] length] > 0);
        assert(![bridge renameTorrent:hash path:@"Album" name:@"Existing" error:nil]);
        assert([[bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"][@"token"] isEqual:conflict[@"token"]]);
        [bridge close];
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:nil];
        assert([[bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"][@"token"] isEqual:conflict[@"token"]]);
        assert(![bridge resolveRenameConflict:hash token:@"obsolete-dialog" error:nil]);
        assert([NSFileManager.defaultManager fileExistsAtPath:collision]);
        NSString *displaced = [payload.path stringByAppendingPathComponent:@"User Moved Conflict"];
        assert([NSFileManager.defaultManager moveItemAtPath:collision toPath:displaced error:nil]);
        assert([NSFileManager.defaultManager createDirectoryAtPath:collision withIntermediateDirectories:NO attributes:nil error:nil]);
        assert(![bridge resolveRenameConflict:hash token:conflict[@"token"] error:nil]);
        assert([NSFileManager.defaultManager fileExistsAtPath:collision]);
        assert([[bridge torrentDetailsForHash:hash error:nil][@"name"] isEqualToString:@"Album"]);
        error = nil;
        assert([bridge renameTorrent:hash path:@"Album" name:@"Renamed" error:&error]);
        assert([bridge renameTorrent:hash path:@"Renamed" name:@"renamed" error:&error]);
        assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:payload.path error:&error] containsObject:@"renamed"]);
        assert([bridge renameTorrent:hash path:@"renamed" name:@"Renamed" error:&error]);
        left = [payload.path stringByAppendingPathComponent:@"Renamed/left.flac.part"];
        right = [payload.path stringByAppendingPathComponent:@"Renamed/right.flac.part"];
        for (int i = 0; i < 100 && ![NSFileManager.defaultManager fileExistsAtPath:left]; ++i) { usleep(100000); }
        [bridge snapshotWithError:&error];
        assert(hidden(left) && hidden(right));
        assert([bridge setWanted:YES forTorrent:hash fileIndices:@[@0] error:&error]);
        assert(!hidden(left) && hidden(right));
        assert([bridge setWanted:NO forTorrent:hash fileIndices:@[@0] error:&error]);
        [bridge close];
        assert([NSFileManager.defaultManager moveItemAtPath:[payload.path stringByAppendingPathComponent:@"Renamed"]
            toPath:[payload.path stringByAppendingPathComponent:@"Moved While Closed"] error:&error]);
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:&error];
        assert(bridge && !error);
        details = [bridge torrentDetailsForHash:hash error:&error];
        assert([details[@"percentDone"] doubleValue] == 1);
        assert([details[@"name"] isEqualToString:@"Moved While Closed"]);
        assert([details[@"status"] intValue] == 0);
        left = [payload.path stringByAppendingPathComponent:@"Moved While Closed/left.flac.part"];
        right = [payload.path stringByAppendingPathComponent:@"Moved While Closed/right.flac.part"];
        assert(hidden(left) && hidden(right));
        assert([bridge setWanted:YES forTorrent:hash fileIndices:@[@0] error:&error]);
        assert(!hidden(left));
        NSString *manual = [payload.path stringByAppendingPathComponent:@"Manual Recovery"];
        assert([NSFileManager.defaultManager copyItemAtPath:[payload.path stringByAppendingPathComponent:@"Moved While Closed"] toPath:manual error:&error]);
        error = nil;
        assert(![bridge locateDataForTorrent:hash atFolder:collision error:&error]);
        assert(error != nil);
        error = nil;
        assert([bridge locateDataForTorrent:hash atFolder:manual error:&error]);
        assert([[bridge torrentDetailsForHash:hash error:&error][@"name"] isEqualToString:@"Manual Recovery"]);
        assert([NSFileManager.defaultManager fileExistsAtPath:[payload.path stringByAppendingPathComponent:@"Moved While Closed"]]);
        assert([NSFileManager.defaultManager fileExistsAtPath:manual]);
        assert([bridge startTorrents:@[hash] error:&error]);
        usleep(200000);
        [bridge close];
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:&error];
        assert(bridge && !error);
        assert([[bridge torrentDetailsForHash:hash error:&error][@"status"] intValue] != 0);
        assert([bridge stopTorrents:@[hash] error:&error]);
        [bridge close];
        assert([NSFileManager.defaultManager removeItemAtPath:manual error:&error]);
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:&error];
        assert(bridge && !error);
        NSDictionary *missing = [bridge snapshotWithError:&error][@"torrents"][0];
        assert([missing[@"error"] intValue] == 3);
        error = nil;
        assert(![bridge startTorrents:@[hash] error:&error]);
        assert(error != nil);
        assert(![NSFileManager.defaultManager fileExistsAtPath:manual]);
        error = nil;
        assert([bridge locateDataForTorrent:hash atFolder:[payload.path stringByAppendingPathComponent:@"Moved While Closed"] error:&error]);
        for (int i = 0; i < 100; ++i) {
            if ([[bridge snapshotWithError:&error][@"torrents"][0][@"error"] intValue] == 0) { break; }
            usleep(100000);
        }
        assert([[bridge snapshotWithError:&error][@"torrents"][0][@"error"] intValue] == 0);
        [bridge close];
        // A persisted creation receipt permits removal only of a proven
        // redundant same-torrent destination. Never remove unique data.
        NSURL *ownedPayload = [root URLByAppendingPathComponent:@"owned-payload"];
        NSURL *ownedConfig = [root URLByAppendingPathComponent:@"owned-config"];
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:ownedConfig downloadDirectory:ownedPayload error:&error];
        assert([bridge addTorrentData:metadata downloadDirectory:ownedPayload.path startPaused:YES error:&error]);
        assert([bridge startTorrents:@[hash] error:&error]);
        assert([bridge stopTorrents:@[hash] error:&error]);
        [bridge close];
        NSString *ownedSource = [ownedPayload.path stringByAppendingPathComponent:@"Album"];
        NSString *ownedDuplicate = [ownedPayload.path stringByAppendingPathComponent:@"Duplicate"];
        assert([NSFileManager.defaultManager moveItemAtPath:ownedSource toPath:ownedDuplicate error:&error]);
        assert([NSFileManager.defaultManager createDirectoryAtPath:ownedSource withIntermediateDirectories:NO attributes:nil error:&error]);
        NSData *sameBytes = [@"known torrent content" dataUsingEncoding:NSUTF8StringEncoding];
        assert([sameBytes writeToFile:[ownedSource stringByAppendingPathComponent:@"middle.flac"] atomically:YES]);
        assert([sameBytes writeToFile:[ownedDuplicate stringByAppendingPathComponent:@"middle.flac"] atomically:YES]);
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:ownedConfig downloadDirectory:ownedPayload error:&error];
        // A file outside the torrent blocks automatic deletion.
        NSString *foreign = [ownedDuplicate stringByAppendingPathComponent:@"personal.txt"];
        assert([sameBytes writeToFile:foreign atomically:YES]);
        error = nil;
        assert(![bridge renameTorrent:hash path:@"Album" name:@"Duplicate" error:&error]);
        assert([NSFileManager.defaultManager fileExistsAtPath:foreign]);
        assert([NSFileManager.defaultManager removeItemAtPath:foreign error:nil]);
        // Different partial bytes are also protected.
        assert([[@"unique bytes" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[ownedDuplicate stringByAppendingPathComponent:@"middle.flac"] atomically:YES]);
        error = nil;
        assert(![bridge renameTorrent:hash path:@"Album" name:@"Duplicate" error:&error]);
        assert([sameBytes writeToFile:[ownedDuplicate stringByAppendingPathComponent:@"middle.flac"] atomically:YES]);
        NSString *linked = [ownedDuplicate stringByAppendingPathComponent:@"left.flac"];
        assert([NSFileManager.defaultManager createSymbolicLinkAtPath:linked withDestinationPath:[ownedSource stringByAppendingPathComponent:@"middle.flac"] error:nil]);
        error = nil;
        assert(![bridge renameTorrent:hash path:@"Album" name:@"Duplicate" error:&error]);
        assert([NSFileManager.defaultManager removeItemAtPath:linked error:nil]);
        error = nil;
        assert([bridge renameTorrent:hash path:@"Album" name:@"Duplicate" error:&error]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:ownedSource]);
        assert([[NSData dataWithContentsOfFile:[ownedDuplicate stringByAppendingPathComponent:@"middle.flac"]] isEqual:sameBytes]);
        // Explicit confirmation may remove an unrelated destination, but only
        // the exact directory shown in the dialog, and it uses Trash.
        NSString *confirmed = [ownedPayload.path stringByAppendingPathComponent:@"Confirmed Conflict"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:confirmed withIntermediateDirectories:NO attributes:nil error:nil]);
        assert([sameBytes writeToFile:[confirmed stringByAppendingPathComponent:@"unrelated.txt"] atomically:YES]);
        assert(![bridge renameTorrent:hash path:@"Duplicate" name:@"Confirmed Conflict" error:nil]);
        NSDictionary *pending = [bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"];
        error = nil;
        BOOL resolved = [bridge resolveRenameConflict:hash token:pending[@"token"] error:&error];
        if (!resolved) { NSLog(@"Conflict resolution failed: %@", error); }
        assert(resolved);
        assert(![NSFileManager.defaultManager fileExistsAtPath:ownedDuplicate]);
        assert([NSFileManager.defaultManager fileExistsAtPath:[confirmed stringByAppendingPathComponent:@"middle.flac"]]);
        assert([[bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"] count] == 0);
        NSString *external = [ownedPayload.path stringByAppendingPathComponent:@"Resolved Externally"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:external withIntermediateDirectories:NO attributes:nil error:nil]);
        assert(![bridge renameTorrent:hash path:@"Confirmed Conflict" name:@"Resolved Externally" error:nil]);
        assert([NSFileManager.defaultManager removeItemAtPath:external error:nil]);
        assert([[bridge snapshotWithError:nil][@"torrents"][0][@"name"] isEqual:@"Resolved Externally"]);
        assert([[bridge snapshotWithError:nil][@"torrents"][0][@"renameConflict"] count] == 0);
        [bridge close];
        puts("Real Transmission bridge: partial files, rename collisions, folder identity recovery, manual location, missing-folder safety, and paused/running restart passed");
    }
}
