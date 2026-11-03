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
        assert([bridge renameTorrent:hash path:@"Album" name:@"Renamed" error:&error]);
        left = [payload.path stringByAppendingPathComponent:@"Renamed/left.flac.part"];
        right = [payload.path stringByAppendingPathComponent:@"Renamed/right.flac.part"];
        for (int i = 0; i < 100 && ![NSFileManager.defaultManager fileExistsAtPath:left]; ++i) { usleep(100000); }
        [bridge snapshotWithError:&error];
        assert(hidden(left) && hidden(right));
        assert([bridge setWanted:YES forTorrent:hash fileIndices:@[@0] error:&error]);
        assert(!hidden(left) && hidden(right));
        assert([bridge setWanted:NO forTorrent:hash fileIndices:@[@0] error:&error]);
        [bridge close];
        bridge = [[LocalTransmissionBridge alloc] initWithConfigDirectory:config downloadDirectory:payload error:&error];
        assert(bridge && !error);
        details = [bridge torrentDetailsForHash:hash error:&error];
        assert([details[@"percentDone"] doubleValue] == 1);
        assert(hidden(left) && hidden(right));
        assert([bridge setWanted:YES forTorrent:hash fileIndices:@[@0] error:&error]);
        assert(!hidden(left));
        [bridge close];
        puts("Real Transmission bridge: selected middle file verifies with hidden boundary fragments; selection, rename and restart passed");
    }
}
