#import "LocalTransmissionBridge.h"
#include "PartialFileVisibility.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>
#include <sys/stat.h>

#include <libtransmission/error.h>
#include <libtransmission/quark.h>
#include <libtransmission/transmission.h>
#include <libtransmission/utils.h>
#include <libtransmission/values.h>
#include <libtransmission/variant.h>

static NSString * const GlassLocalTransmissionErrorDomain = @"GlassLocalTransmissionError";

static NSError *GlassError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:GlassLocalTransmissionErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static NSString *StringFromView(std::string_view view) {
    return [[NSString alloc] initWithBytes:view.data() length:view.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *StringFromCString(char const *string) {
    return string == nullptr ? @"" : [NSString stringWithUTF8String:string] ?: @"";
}

static NSNumber *BytesPerSecond(tr::Values::Speed const& speed) {
    return @(speed.count(tr::Values::SpeedUnits::Byps));
}

static std::vector<tr_file_index_t> FileIndices(NSArray<NSNumber *> *numbers);

@interface LocalTransmissionBridge ()
@property(nonatomic) tr_session *session;
@property(nonatomic, copy) NSString *configPath;
@property(nonatomic, copy) NSString *downloadPath;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *partialVisibilityStates;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *dataBookmarks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *createdRoots;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *renameConflicts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *dataLocationErrors;
@end

@implementation LocalTransmissionBridge

- (instancetype)initWithConfigDirectory:(NSURL *)configDirectory
                      downloadDirectory:(NSURL *)downloadDirectory
                                  error:(NSError **)error
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    tr_lib_init();

    _partialVisibilityStates = [NSMutableDictionary dictionary];
    _configPath = configDirectory.path;
    _downloadPath = downloadDirectory.path;
    NSString *bookmarksPath = [_configPath stringByAppendingPathComponent:@"data-bookmarks.plist"];
    _dataBookmarks = [[NSDictionary dictionaryWithContentsOfFile:bookmarksPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    _dataLocationErrors = [NSMutableDictionary dictionary];
    _renameConflicts = [[NSDictionary dictionaryWithContentsOfFile:[_configPath stringByAppendingPathComponent:@"rename-conflicts.plist"]] mutableCopy] ?: [NSMutableDictionary dictionary];
    _createdRoots = [[NSDictionary dictionaryWithContentsOfFile:[_configPath stringByAppendingPathComponent:@"created-roots.plist"]] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager createDirectoryAtURL:configDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    if (![fileManager createDirectoryAtURL:downloadDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    std::string config = _configPath.UTF8String;
    std::string downloads = _downloadPath.UTF8String;
    tr_variant settings = tr_sessionLoadSettings(config);
    if (auto *map = settings.get_if<tr_variant::Map>()) {
        map->insert_or_assign(TR_KEY_download_dir, downloads);
        map->insert_or_assign(TR_KEY_lpd_enabled, false);
        map->insert_or_assign(TR_KEY_port_forwarding_enabled, false);
        map->insert_or_assign(TR_KEY_rpc_enabled, false);
    }

    _session = tr_sessionInit(config, true, settings);
    if (_session == nullptr) {
        if (error != nullptr) {
            *error = GlassError(1, @"Could not start local libtransmission session.");
        }
        return nil;
    }

    // Restore paused first: a renamed directory must be resolved before the
    // engine can recreate its old path. Preserve each saved running state.
    NSMutableSet<NSString *> *runningHashes = [NSMutableSet set];
    NSString *resumeDirectory = [_configPath stringByAppendingPathComponent:@"resume"];
    for (NSString *file in [fileManager contentsOfDirectoryAtPath:resumeDirectory error:nil]) {
        if (![file.pathExtension isEqualToString:@"resume"]) { continue; }
        auto resume = tr_variant_serde::benc().parse_file([resumeDirectory stringByAppendingPathComponent:file].UTF8String);
        if (resume) {
            if (auto map = resume->get_if<tr_variant::Map>()) {
                if (auto paused = map->value_if<bool>(TR_KEY_paused); paused && !*paused) {
                    [runningHashes addObject:file.stringByDeletingPathExtension];
                }
            }
        }
    }
    tr_ctor *ctor = tr_ctorNew(_session);
    tr_ctorSetPaused(ctor, TR_FORCE, true);
    tr_sessionLoadTorrents(_session, ctor);
    tr_ctorFree(ctor);
    size_t count = tr_sessionGetAllTorrents(_session, nullptr, 0);
    std::vector<tr_torrent *> loaded(count);
    tr_sessionGetAllTorrents(_session, loaded.data(), count);
    for (tr_torrent *torrent : loaded) {
        NSString *hash = StringFromCString(tr_torrentView(torrent).hash_string);
        if ([self reconcileDataLocation:torrent] && [runningHashes containsObject:hash] && [self prepareCreatedRoot:torrent error:nil]) { tr_torrentStart(torrent); }
    }

    return self;
}

- (void)close
{
    if (_session != nullptr) {
        tr_sessionClose(_session);
        _session = nullptr;
    }
}

- (void)dealloc { [self close]; }

- (NSDictionary *)snapshotWithError:(NSError **)error
{
    if (![self ensureSession:error]) {
        return @{};
    }

    tr_session_stats const stats = tr_sessionGetStats(self.session);
    NSArray *torrents = [self torrentDictionaries];

    return @{
        @"stats": @{
            @"downloadSpeed": @(tr_sessionGetRawSpeed_KBps(self.session, tr_direction::Down) * 1000.0),
            @"uploadSpeed": @(tr_sessionGetRawSpeed_KBps(self.session, tr_direction::Up) * 1000.0),
            @"ratio": @(stats.ratio)
        },
        @"torrents": torrents
    };
}

- (nullable NSString *)defaultDownloadDirectoryWithError:(NSError **)error
{
    if (![self ensureSession:error]) {
        return nil;
    }
    return StringFromView(tr_sessionGetDownloadDir(self.session));
}

- (NSDictionary *)torrentDetailsForHash:(NSString *)hashString error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return @{};
    }

    NSMutableDictionary *dictionary = [[self dictionaryForTorrent:torrent] mutableCopy];
    tr_stat const stat = tr_torrentStat(torrent);
    tr_torrent_view const view = tr_torrentView(torrent);

    dictionary[@"totalSize"] = @(view.total_size);
    dictionary[@"uploadedEver"] = @(stat.uploaded_ever);
    dictionary[@"downloadedEver"] = @(stat.downloaded_ever);
    dictionary[@"corruptEver"] = @(stat.corrupt_ever);
    dictionary[@"addedDate"] = @(stat.added_date);
    dictionary[@"activityDate"] = @(stat.activity_date);
    dictionary[@"startDate"] = @(stat.start_date);
    dictionary[@"doneDate"] = @(stat.done_date);
    dictionary[@"secondsDownloading"] = @(stat.seconds_downloading);
    dictionary[@"secondsSeeding"] = @(stat.seconds_seeding);
    dictionary[@"pieceCount"] = @(view.n_pieces);
    dictionary[@"pieceSize"] = @(view.piece_size);
    dictionary[@"isPrivate"] = @(view.is_private);

    NSMutableArray *files = [NSMutableArray array];
    NSMutableArray *fileStats = [NSMutableArray array];
    size_t const fileCount = tr_torrentFileCount(torrent);
    for (tr_file_index_t i = 0; i < fileCount; ++i) {
        tr_file_view const file = tr_torrentFile(torrent, i);
        [files addObject:@{
            @"name": StringFromCString(file.name),
            @"length": @(file.length),
            @"bytesCompleted": @(file.have)
        }];
        [fileStats addObject:@{
            @"bytesCompleted": @(file.have),
            @"wanted": @(file.wanted),
            @"priority": @(file.priority)
        }];
    }
    dictionary[@"files"] = files;
    dictionary[@"fileStats"] = fileStats;

    NSMutableArray *peers = [NSMutableArray array];
    for (auto const& peer : tr_torrentPeers(torrent)) {
        [peers addObject:@{
            @"address": [NSString stringWithUTF8String:peer.addr.c_str()] ?: @"",
            @"port": @(peer.port),
            @"clientName": [NSString stringWithUTF8String:peer.user_agent.c_str()] ?: @"",
            @"flagStr": [NSString stringWithUTF8String:peer.flag_str.c_str()] ?: @"",
            @"progress": @(peer.progress),
            @"rateToClient": BytesPerSecond(peer.rate_to_client),
            @"rateToPeer": BytesPerSecond(peer.rate_to_peer),
            @"isEncrypted": @(peer.is_encrypted),
            @"isIncoming": @(peer.is_incoming),
            @"isUTP": @(peer.is_utp)
        }];
    }
    dictionary[@"peers"] = peers;

    NSMutableArray *trackers = [NSMutableArray array];
    size_t const trackerCount = tr_torrentTrackerCount(torrent);
    for (size_t i = 0; i < trackerCount; ++i) {
        tr_tracker_view const tracker = tr_torrentTracker(torrent, i);
        [trackers addObject:@{
            @"id": @(tracker.id),
            @"announce": StringFromCString(tracker.announce),
            @"scrape": StringFromCString(tracker.scrape),
            @"host": StringFromCString(tracker.host_and_port),
            @"tier": @(tracker.tier),
            @"lastAnnounceResult": StringFromCString(tracker.lastAnnounceResult),
            @"lastAnnounceSucceeded": @(tracker.lastAnnounceSucceeded),
            @"lastScrapeResult": StringFromCString(tracker.lastScrapeResult),
            @"lastScrapeSucceeded": @(tracker.lastScrapeSucceeded),
            @"seederCount": @(tracker.seederCount),
            @"leecherCount": @(tracker.leecherCount),
            @"downloadCount": @(tracker.downloadCount),
            @"nextAnnounceTime": @(tracker.nextAnnounceTime)
        }];
    }
    dictionary[@"trackerStats"] = trackers;

    return dictionary;
}

// Preview sessions are separate from the user's engine. Zero piece-transfer
// limits are installed before starting; BEP 9 metadata exchanges still run.
- (BOOL)addMetadataMagnet:(NSString *)magnet error:(NSError **)error
{
    if (![self ensureSession:error]) { return NO; }
    tr_sessionSetPeerPortRandom(self.session);
    tr_ctor *ctor = tr_ctorNew(self.session);
    tr_ctorSetPaused(ctor, TR_FORCE, true);
    if (!tr_ctorSetMetainfoFromMagnetLink(ctor, magnet.UTF8String)) {
        tr_ctorFree(ctor);
        if (error != nullptr) { *error = GlassError(2, @"The magnet link could not be read."); }
        return NO;
    }
    tr_torrent *torrent = tr_torrentNew(ctor, nullptr);
    tr_ctorFree(ctor);
    if (torrent == nullptr) {
        if (error != nullptr) { *error = GlassError(3, @"The magnet preview could not be started."); }
        return NO;
    }
    tr_torrentSetSpeedLimit_KBps(torrent, tr_direction::Down, 0);
    tr_torrentUseSpeedLimit(torrent, tr_direction::Down, true);
    tr_torrentUseSessionLimits(torrent, false);
    tr_torrentStart(torrent);
    return YES;
}

- (nullable NSData *)exportMetainfoForHash:(NSString *)hashString error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) { return nil; }
    NSString *path = StringFromView(tr_torrentFilename(torrent));
    return [NSData dataWithContentsOfFile:path options:0 error:error];
}

- (nullable NSData *)resolvedMetainfo
{
    if (self.session == nullptr) { return nil; }
    tr_torrent *torrent = nullptr;
    if (tr_sessionGetAllTorrents(self.session, &torrent, 1) == 0) { return nil; }
    tr_stat const stat = tr_torrentStat(torrent);
    if (stat.metadata_percent_complete < 1) { return nil; }
    NSString *path = StringFromView(tr_torrentFilename(torrent));
    // The engine's metainfo write can trail the metadata-complete event.
    return [NSData dataWithContentsOfFile:path];
}

- (BOOL)addMagnet:(NSString *)magnet downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error
{
    return [self addWithConfigure:^(tr_ctor *ctor) {
        return tr_ctorSetMetainfoFromMagnetLink(ctor, magnet.UTF8String);
    } downloadDirectory:downloadDirectory startPaused:NO error:error];
}

- (BOOL)addTorrentData:(NSData *)data downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error
{
    return [self addWithConfigure:^(tr_ctor *ctor) {
        return tr_ctorSetMetainfo(ctor, static_cast<char const *>(data.bytes), data.length, nullptr);
    } downloadDirectory:downloadDirectory startPaused:NO error:error];
}

- (BOOL)addTorrentData:(NSData *)data downloadDirectory:(nullable NSString *)downloadDirectory startPaused:(BOOL)startPaused error:(NSError **)error
{
    return [self addWithConfigure:^(tr_ctor *ctor) {
        return tr_ctorSetMetainfo(ctor, static_cast<char const *>(data.bytes), data.length, nullptr);
    } downloadDirectory:downloadDirectory startPaused:startPaused error:error];
}

- (BOOL)startTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
    for (NSString *hash in hashes) {
        tr_torrent *torrent = [self torrentForHash:hash error:error];
        if (!torrent) { return NO; }
        if (![self reconcileDataLocation:torrent]) {
            if (error) { *error = GlassError(ENOENT, self.dataLocationErrors[hash]); }
            return NO;
        }
        if (![self prepareCreatedRoot:torrent error:error]) { return NO; }
    }
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentStart(torrent);
    }];
}

- (BOOL)stopTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentStop(torrent);
    }];
}

- (BOOL)removeTorrents:(NSArray<NSString *> *)hashes deleteLocalData:(BOOL)deleteLocalData error:(NSError **)error
{
    [self.partialVisibilityStates removeAllObjects];
    BOOL removed = [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentRemove(torrent, deleteLocalData);
    }];
    if (removed) {
        [self.dataBookmarks removeObjectsForKeys:hashes];
        [self.renameConflicts removeObjectsForKeys:hashes];
        [self.renameConflicts writeToFile:[self.configPath stringByAppendingPathComponent:@"rename-conflicts.plist"] atomically:YES];
        [self.dataLocationErrors removeObjectsForKeys:hashes];
        [self.dataBookmarks writeToFile:[self.configPath stringByAppendingPathComponent:@"data-bookmarks.plist"] atomically:YES];
    }
    return removed;
}

- (BOOL)verifyTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentVerify(torrent);
    }];
}

- (BOOL)reannounceTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        if (tr_torrentCanManualUpdate(torrent)) {
            tr_torrentManualUpdate(torrent);
        }
    }];
}

- (BOOL)moveTorrents:(NSArray<NSString *> *)hashes toQueuePosition:(NSInteger)queuePosition error:(NSError **)error
{
    __block NSInteger offset = 0;
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentSetQueuePosition(torrent, static_cast<size_t>(std::max<NSInteger>(0, queuePosition + offset)));
        offset += 1;
    }];
}

- (BOOL)moveDataForTorrent:(NSString *)hashString
       toDownloadDirectory:(NSString *)downloadDirectory
                     error:(NSError **)error
{
    if (downloadDirectory.length == 0) {
        if (error != nullptr) {
            *error = GlassError(5, @"Choose a destination folder.");
        }
        return NO;
    }

    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }

    int volatile state = TR_LOC_MOVING;
    tr_torrentSetLocation(torrent, downloadDirectory.UTF8String, true, &state);
    while (state == TR_LOC_MOVING) {
        [NSThread sleepForTimeInterval:0.02];
    }

    if (state != TR_LOC_DONE) {
        if (error != nullptr) {
            *error = GlassError(6, @"Transmission could not move the torrent data to the selected folder.");
        }
        return NO;
    }
    // Explicit moves can cross volumes and therefore create a new file identity.
    [self.dataBookmarks removeObjectForKey:hashString];
    [self reconcileDataLocation:torrent];
    return YES;
}

- (BOOL)locateDataForTorrent:(NSString *)hashString atFolder:(NSString *)folder error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (!torrent) { return NO; }
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:folder isDirectory:&directory] || !directory) {
        if (error) { *error = GlassError(ENOENT, @"Choose the existing folder containing this torrent's files."); }
        return NO;
    }
    NSString *oldName = StringFromCString(tr_torrentView(torrent).name);
    BOOL matches = NO;
    for (tr_file_index_t i = 0; i < tr_torrentFileCount(torrent); ++i) {
        auto file = tr_torrentFile(torrent, i);
        NSString *relative = StringFromCString(file.name);
        NSString *prefix = [oldName stringByAppendingString:@"/"];
        if (![relative hasPrefix:prefix]) { continue; }
        relative = [relative substringFromIndex:prefix.length];
        NSString *candidate = [folder stringByAppendingPathComponent:relative];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) { candidate = [candidate stringByAppendingString:@".part"]; }
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:candidate error:nil];
        if (attributes && [attributes fileSize] <= file.length) { matches = YES; }
    }
    if (!matches) {
        if (error) { *error = GlassError(EINVAL, @"That folder does not contain files from this torrent."); }
        return NO;
    }
    tr_torrentStop(torrent);
    int volatile state = TR_LOC_MOVING;
    tr_torrentSetLocation(torrent, [folder stringByDeletingLastPathComponent].UTF8String, false, &state);
    while (state == TR_LOC_MOVING) { [NSThread sleepForTimeInterval:0.02]; }
    if (state != TR_LOC_DONE) { if (error) { *error = GlassError(EIO, @"The existing folder could not be selected."); } return NO; }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    int code = 0;
    tr_torrentRenamePath(torrent, oldName.UTF8String, folder.lastPathComponent.UTF8String,
        [done, &code](tr_torrent_id_t, std::string_view, std::string_view, tr_error const& result) {
            code = result.code(); dispatch_semaphore_signal(done);
        });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (code) { if (error) { *error = GlassError(code, @"The existing folder could not be selected."); } return NO; }
    // Refresh the engine's current directory/error after the root name changed.
    state = TR_LOC_MOVING;
    tr_torrentSetLocation(torrent, [folder stringByDeletingLastPathComponent].UTF8String, false, &state);
    while (state == TR_LOC_MOVING) { [NSThread sleepForTimeInterval:0.02]; }
    [self.dataBookmarks removeObjectForKey:hashString];
    [self.dataLocationErrors removeObjectForKey:hashString];
    [self reconcileDataLocation:torrent];
    // Selection never moves or deletes either folder. Recheck pieces before
    // permitting resumed downloads into data that may differ from the old path.
    tr_torrentVerify(torrent);
    return YES;
}

// Receipt keys bind ownership to a filesystem object, not a reusable pathname.
- (NSString *)identityOfDirectory:(NSString *)path
{
    if (path.length == 0) { return nil; }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) { return nil; }
    return [NSString stringWithFormat:@"%@:%@:%@", attributes[NSFileSystemNumber],
        attributes[NSFileSystemFileNumber], attributes[NSFileCreationDate]];
}

- (BOOL)prepareCreatedRoot:(tr_torrent *)torrent error:(NSError **)error
{
    if (tr_torrentFileCount(torrent) < 2) { return YES; }
    NSString *root = [StringFromView(tr_torrentGetDownloadDir(torrent))
        stringByAppendingPathComponent:StringFromCString(tr_torrentView(torrent).name)];
    if ([NSFileManager.defaultManager fileExistsAtPath:root]) { return YES; }
    // mkdir is exclusive: never claim a directory merely because it appeared
    // while Transmission was running, or because its filenames look familiar.
    if (mkdir(root.fileSystemRepresentation, 0755) != 0) {
        if (error) { *error = GlassError(errno, @"The download folder could not be created."); }
        return NO;
    }
    NSString *identity = [self identityOfDirectory:root];
    if (!identity) { return NO; }
    self.createdRoots[identity] = StringFromCString(tr_torrentView(torrent).hash_string);
    if (![self.createdRoots writeToFile:[self.configPath stringByAppendingPathComponent:@"created-roots.plist"] atomically:YES]) {
        [self.createdRoots removeObjectForKey:identity];
        if (error) { *error = GlassError(EIO, @"The download folder ownership record could not be saved."); }
        return NO;
    }
    return YES;
}

- (BOOL)removeRedundantCreatedRoot:(NSString *)destination source:(NSString *)source torrent:(tr_torrent *)torrent
{
    NSString *identity = [self identityOfDirectory:destination];
    NSString *hash = StringFromCString(tr_torrentView(torrent).hash_string);
    if (!identity || ![self.createdRoots[identity] isEqual:hash] || ![self identityOfDirectory:source]) { return NO; }
    // Every destination file must belong to this torrent and have identical
    // bytes in the selected source. Unknown files, symlinks and unique partial
    // data are conflicts, even inside a directory Glass originally created.
    NSMutableSet *allowed = [NSMutableSet set];
    NSString *prefix = [StringFromCString(tr_torrentView(torrent).name) stringByAppendingString:@"/"];
    for (tr_file_index_t i = 0; i < tr_torrentFileCount(torrent); ++i) {
        NSString *name = StringFromCString(tr_torrentFile(torrent, i).name);
        if ([name hasPrefix:prefix]) { [allowed addObject:[name substringFromIndex:prefix.length]]; }
    }
    NSArray *entries = [NSFileManager.defaultManager subpathsOfDirectoryAtPath:destination error:nil];
    if (!entries) { return NO; }
    for (NSString *relative in entries) {
        NSString *path = [destination stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            BOOL expectedDirectory = NO;
            for (NSString *file in allowed) { if ([file hasPrefix:[relative stringByAppendingString:@"/"]]) { expectedDirectory = YES; break; } }
            if (!expectedDirectory) { return NO; }
            continue;
        }
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) { return NO; }
        NSString *logical = [relative hasSuffix:@".part"] ? [relative substringToIndex:relative.length - 5] : relative;
        if (![allowed containsObject:logical]) { return NO; }
        NSString *other = [source stringByAppendingPathComponent:logical];
        if (![NSFileManager.defaultManager fileExistsAtPath:other]) { other = [other stringByAppendingString:@".part"]; }
        if (![[NSFileManager.defaultManager attributesOfItemAtPath:other error:nil][NSFileType] isEqual:NSFileTypeRegular] ||
            ![NSFileManager.defaultManager contentsEqualAtPath:path andPath:other]) { return NO; }
    }
    if (![[self identityOfDirectory:destination] isEqual:identity]) { return NO; }
    if (![NSFileManager.defaultManager removeItemAtPath:destination error:nil]) { return NO; }
    [self.createdRoots removeObjectForKey:identity];
    [self.createdRoots writeToFile:[self.configPath stringByAppendingPathComponent:@"created-roots.plist"] atomically:YES];
    return YES;
}

- (BOOL)renameTorrent:(NSString *)hashString path:(NSString *)path name:(NSString *)name error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }
    if (name.length == 0 || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        if (error) { *error = GlassError(EINVAL, @"Choose a valid file or folder name."); }
        return NO;
    }
    NSString *base = StringFromView(tr_torrentGetDownloadDir(torrent));
    NSString *source = [base stringByAppendingPathComponent:path];
    NSString *destination = [[source stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
    NSString *physicalSource = source;
    NSString *physicalDestination = destination;
    if (![NSFileManager.defaultManager fileExistsAtPath:physicalSource] &&
        [NSFileManager.defaultManager fileExistsAtPath:[physicalSource stringByAppendingString:@".part"]]) {
        physicalSource = [physicalSource stringByAppendingString:@".part"];
        physicalDestination = [physicalDestination stringByAppendingString:@".part"];
    }
    NSDictionary *sourceAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:physicalSource error:nil];
    NSDictionary *destinationAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:physicalDestination error:nil];
    BOOL sameFile = sourceAttributes && destinationAttributes &&
        [sourceAttributes[NSFileSystemNumber] isEqual:destinationAttributes[NSFileSystemNumber]] &&
        [sourceAttributes[NSFileSystemFileNumber] isEqual:destinationAttributes[NSFileSystemFileNumber]];
    BOOL caseOnly = sameFile && [source caseInsensitiveCompare:destination] == NSOrderedSame;
    if (!caseOnly && ![source isEqualToString:destination] &&
        ([NSFileManager.defaultManager fileExistsAtPath:destination] ||
         [NSFileManager.defaultManager fileExistsAtPath:[destination stringByAppendingString:@".part"]])) {
        BOOL isRoot = [path isEqualToString:StringFromCString(tr_torrentView(torrent).name)];
        if (!isRoot || ![self removeRedundantCreatedRoot:destination source:source torrent:torrent]) {
            if (isRoot && [self identityOfDirectory:destination]) {
                NSDictionary *previous = self.renameConflicts[hashString];
                BOOL sameConflict = [previous[@"destination"] isEqual:destination] && [previous[@"path"] isEqual:path] &&
                    [previous[@"identity"] isEqual:[self identityOfDirectory:destination]] &&
                    [previous[@"sourceIdentity"] isEqual:([self identityOfDirectory:source] ?: @"")];
                self.renameConflicts[hashString] = @{
                    @"token": sameConflict ? previous[@"token"] : NSUUID.UUID.UUIDString, @"destination": destination,
                    @"name": name, @"path": path, @"identity": [self identityOfDirectory:destination],
                    @"sourceIdentity": [self identityOfDirectory:source] ?: @""
                };
                [self.renameConflicts writeToFile:[self.configPath stringByAppendingPathComponent:@"rename-conflicts.plist"] atomically:YES];
            }
            if (error) { *error = GlassError(EEXIST, [NSString stringWithFormat:
                @"Could not rename “%@” to “%@”: the destination already exists. Glass could not prove it is a redundant folder it created for this torrent. Both folders were preserved; choose a different name or resolve the existing folder first.", path, name]); }
            return NO;
        }
    }
    if (caseOnly && ![source isEqualToString:destination] &&
        rename(physicalSource.fileSystemRepresentation, physicalDestination.fileSystemRepresentation) != 0) {
        if (error) { *error = GlassError(errno, @"The file or folder could not be renamed."); }
        return NO;
    }
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    NSError *renameError = nil;
    tr_torrentRenamePath(torrent, path.UTF8String, name.UTF8String,
        [finished, &renameError](tr_torrent_id_t, std::string_view, std::string_view, tr_error const& result) {
            if (result) { renameError = GlassError(result.code(), StringFromView(result.message())); }
            dispatch_semaphore_signal(finished);
        });
    // The Swift session actor owns this blocking bridge call; the UI thread is
    // never held while Transmission performs its asynchronous filesystem rename.
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (renameError) { if (error) { *error = renameError; } return NO; }
    [self.renameConflicts removeObjectForKey:hashString];
    [self.renameConflicts writeToFile:[self.configPath stringByAppendingPathComponent:@"rename-conflicts.plist"] atomically:YES];
    return YES;
}

- (BOOL)resolveRenameConflict:(NSString *)hashString token:(NSString *)token error:(NSError **)error
{
    NSDictionary *conflict = self.renameConflicts[hashString];
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    NSString *destination = conflict[@"destination"];
    // A dialog authorizes this exact object, not whatever later occupies its path.
    if (!torrent || ![conflict[@"token"] isEqual:token] ||
        ![[self identityOfDirectory:destination] isEqual:conflict[@"identity"]] ||
        ![StringFromCString(tr_torrentView(torrent).name) isEqual:conflict[@"path"]]) {
        if (error) { *error = GlassError(EINVAL, @"The folder conflict changed. Review it again before deleting anything."); }
        return NO;
    }
    NSString *source = [StringFromView(tr_torrentGetDownloadDir(torrent)) stringByAppendingPathComponent:conflict[@"path"]];
    NSString *expected = [[source stringByDeletingLastPathComponent] stringByAppendingPathComponent:conflict[@"name"]];
    NSString *sourceIdentity = [self identityOfDirectory:source];
    BOOL newDownload = [conflict[@"sourceIdentity"] length] == 0 && !sourceIdentity && tr_torrentStat(torrent).downloaded_ever == 0;
    if (![expected isEqual:destination] || (!newDownload && ![sourceIdentity isEqual:conflict[@"sourceIdentity"]]) ||
        [sourceIdentity isEqual:conflict[@"identity"]]) {
        if (error) { *error = GlassError(EINVAL, @"The download location changed. No folder was deleted."); }
        return NO;
    }
    NSURL *trashed = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:destination] resultingItemURL:&trashed error:error]) { return NO; }
    if (![self renameTorrent:hashString path:conflict[@"path"] name:conflict[@"name"] error:error]) {
        // Restore the old folder when retrying the rename failed without creating
        // a new destination. Never overwrite data during rollback.
        if (![NSFileManager.defaultManager fileExistsAtPath:destination]) {
            [NSFileManager.defaultManager moveItemAtURL:trashed toURL:[NSURL fileURLWithPath:destination] error:nil];
        }
        return NO;
    }
    return YES;
}

- (BOOL)setWanted:(BOOL)wanted forTorrent:(NSString *)hashString fileIndices:(NSArray<NSNumber *> *)fileIndices error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }
    std::vector<tr_file_index_t> files = FileIndices(fileIndices);
    // Restore visibility before the engine can finish/rename a reselected file.
    if (wanted) {
        for (auto index : files) {
            if (index >= tr_torrentFileCount(torrent)) { continue; }
            auto const path = tr_torrentFindFile(torrent, index);
            if (!path.empty()) { GlassUpdatePartialFileVisibility(path.c_str(), true, true); }
        }
    }
    tr_torrentSetFileDLs(torrent, files.data(), static_cast<tr_file_index_t>(files.size()), wanted);
    [self refreshPartialFileVisibility:torrent];
    return YES;
}

- (BOOL)setPriority:(NSInteger)priority forTorrent:(NSString *)hashString fileIndices:(NSArray<NSNumber *> *)fileIndices error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }
    std::vector<tr_file_index_t> files = FileIndices(fileIndices);
    tr_torrentSetFilePriorities(torrent, files.data(), static_cast<tr_file_index_t>(files.size()), static_cast<tr_priority_t>(priority));
    return YES;
}

- (BOOL)setPriority:(NSInteger)priority forTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentSetPriority(torrent, static_cast<tr_priority_t>(priority));
    }];
}

- (BOOL)addWithConfigure:(bool (^)(tr_ctor *ctor))configure
       downloadDirectory:(nullable NSString *)downloadDirectory
             startPaused:(BOOL)startPaused
                   error:(NSError **)error
{
    if (![self ensureSession:error]) {
        return NO;
    }
    tr_ctor *ctor = tr_ctorNew(self.session);
    tr_ctorSetPaused(ctor, TR_FORCE, true);
    if (downloadDirectory.length > 0) {
        tr_ctorSetDownloadDir(ctor, TR_FORCE, downloadDirectory.UTF8String);
    }
    bool const configured = configure(ctor);
    if (!configured) {
        tr_ctorFree(ctor);
        if (error != nullptr) {
            *error = GlassError(2, @"The torrent metadata could not be read.");
        }
        return NO;
    }
    tr_torrent *duplicate = nullptr;
    tr_torrent *torrent = tr_torrentNew(ctor, &duplicate);
    tr_ctorFree(ctor);
    if (torrent == nullptr && duplicate == nullptr) {
        if (error != nullptr) {
            *error = GlassError(3, @"The torrent could not be added.");
        }
        return NO;
    }
    if (torrent && !startPaused) {
        if (![self prepareCreatedRoot:torrent error:error]) { return NO; }
        tr_torrentStart(torrent);
    }
    return YES;
}

- (NSArray *)torrentDictionaries
{
    size_t const count = tr_sessionGetAllTorrents(self.session, nullptr, 0);
    std::vector<tr_torrent *> torrents(count);
    tr_sessionGetAllTorrents(self.session, torrents.data(), count);

    NSMutableArray *array = [NSMutableArray arrayWithCapacity:count];
    for (tr_torrent *torrent : torrents) {
        [array addObject:[self dictionaryForTorrent:torrent]];
    }
    return array;
}

// Called on LocalTransmissionSession's actor, never the main/UI thread. Cache
// unchanged states so stopped/complete torrents do not repeatedly touch disk.
- (void)refreshPartialFileVisibility:(tr_torrent *)torrent
{
    auto const view = tr_torrentView(torrent);
    NSString *hash = StringFromCString(view.hash_string);
    NSString *directory = StringFromView(tr_torrentGetCurrentDir(torrent));
    for (tr_file_index_t i = 0; i < tr_torrentFileCount(torrent); ++i) {
        auto const file = tr_torrentFile(torrent, i);
        if (file.have == 0) { continue; }
        NSString *key = [NSString stringWithFormat:@"%@: %zu", hash, i];
        NSString *state = [NSString stringWithFormat:@"%@/%s:%llu:%d", directory, file.name,
            (unsigned long long)file.have, file.wanted];
        if ([self.partialVisibilityStates[key] isEqualToString:state]) { continue; }
        auto const path = tr_torrentFindFile(torrent, i);
        if (path.empty()) { continue; } // A boundary write may appear on the next refresh.
        // A legitimate payload filename may itself end in .part. Only the
        // engine-added suffix counts as incomplete-file storage.
        std::string const partialSuffix = std::string(file.name) + ".part";
        bool const partial = path.ends_with("/" + partialSuffix);
        if (GlassUpdatePartialFileVisibility(path.c_str(), file.wanted, partial)) {
            self.partialVisibilityStates[key] = state;
        }
    }
}

- (BOOL)reconcileDataLocation:(tr_torrent *)torrent
{
    tr_torrent_view view = tr_torrentView(torrent);
    NSString *hash = StringFromCString(view.hash_string);
    NSString *name = StringFromCString(view.name);
    NSURL *expected = [[NSURL fileURLWithPath:StringFromView(tr_torrentGetDownloadDir(torrent))]
        URLByAppendingPathComponent:name];
    expected = expected.URLByResolvingSymlinksInPath;
    NSData *bookmark = self.dataBookmarks[hash];
    BOOL stale = NO;
    NSURL *tracked = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark
        options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
        relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
    BOOL isDirectory = NO;
    if (bookmark && (!tracked || ![NSFileManager.defaultManager fileExistsAtPath:tracked.path isDirectory:&isDirectory])) {
        self.dataLocationErrors[hash] = @"Download folder is missing. Choose its current location to continue.";
        tr_torrentStop(torrent);
        return NO;
    }
    BOOL resumeAfterRecovery = NO;
    if (!bookmark && tr_torrentFileCount(torrent) > 1 && tr_torrentStat(torrent).downloaded_ever > 0 &&
        ![NSFileManager.defaultManager fileExistsAtPath:expected.path]) {
        self.dataLocationErrors[hash] = @"Download folder is missing. Choose its current location to continue.";
        tr_torrentStop(torrent);
        return NO;
    }
    if (tracked && ![tracked.URLByResolvingSymlinksInPath.path isEqualToString:expected.path]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:expected.path]) {
            self.dataLocationErrors[hash] = @"The download folder moved and another folder now exists at the old path. Choose which existing folder to use.";
            tr_torrentStop(torrent);
            return NO;
        }
        // This is the same filesystem object, not a guess based on a name.
        int volatile state = TR_LOC_MOVING;
        auto activity = tr_torrentStat(torrent).activity;
        resumeAfterRecovery = activity == TR_STATUS_DOWNLOAD || activity == TR_STATUS_DOWNLOAD_WAIT ||
            activity == TR_STATUS_SEED || activity == TR_STATUS_SEED_WAIT;
        tr_torrentStop(torrent);
        tr_torrentSetLocation(torrent, tracked.URLByDeletingLastPathComponent.path.UTF8String, false, &state);
        while (state == TR_LOC_MOVING) { [NSThread sleepForTimeInterval:0.02]; }
        if (state != TR_LOC_DONE) {
            self.dataLocationErrors[hash] = @"The moved download folder could not be reconnected.";
            return NO;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        int renameCode = 0;
        tr_torrentRenamePath(torrent, name.UTF8String, tracked.lastPathComponent.UTF8String,
            [done, &renameCode](tr_torrent_id_t, std::string_view, std::string_view, tr_error const& result) {
                renameCode = result.code(); dispatch_semaphore_signal(done);
            });
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (renameCode != 0) {
            self.dataLocationErrors[hash] = @"The moved download folder could not be reconnected.";
            return NO;
        }
        // Root metadata now points to the tracked inode; refresh file lookup
        // and clear the old "No data found" error without starting downloads.
        state = TR_LOC_MOVING;
        tr_torrentSetLocation(torrent, tracked.URLByDeletingLastPathComponent.path.UTF8String, false, &state);
        while (state == TR_LOC_MOVING) { [NSThread sleepForTimeInterval:0.02]; }
        expected = tracked;
        stale = YES;
    }
    if (!bookmark || stale) {
        if ([NSFileManager.defaultManager fileExistsAtPath:expected.path isDirectory:&isDirectory] && isDirectory) {
            NSData *data = [expected bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
            if (data) {
                self.dataBookmarks[hash] = data;
                [self.dataBookmarks writeToFile:[self.configPath stringByAppendingPathComponent:@"data-bookmarks.plist"] atomically:YES];
            }
        }
    }
    [self.dataLocationErrors removeObjectForKey:hash];
    if (resumeAfterRecovery) { tr_torrentStart(torrent); }
    return YES;
}

- (void)refreshRenameConflict:(tr_torrent *)torrent
{
    NSString *hash = StringFromCString(tr_torrentView(torrent).hash_string);
    NSDictionary *conflict = self.renameConflicts[hash];
    if (!conflict) { return; }
    NSString *source = [StringFromView(tr_torrentGetDownloadDir(torrent)) stringByAppendingPathComponent:conflict[@"path"]];
    NSString *sourceIdentity = [self identityOfDirectory:source];
    BOOL newDownload = [conflict[@"sourceIdentity"] length] == 0 && !sourceIdentity && tr_torrentStat(torrent).downloaded_ever == 0;
    if (![StringFromCString(tr_torrentView(torrent).name) isEqual:conflict[@"path"]] ||
        (!newDownload && ![sourceIdentity isEqual:conflict[@"sourceIdentity"]])) { return; }
    NSString *destination = conflict[@"destination"];
    if (![NSFileManager.defaultManager fileExistsAtPath:destination]) {
        // The user resolved the collision in Finder; finish the existing intent.
        [self renameTorrent:hash path:conflict[@"path"] name:conflict[@"name"] error:nil];
    } else {
        NSString *identity = [self identityOfDirectory:destination];
        if (identity && ![identity isEqual:conflict[@"identity"]]) {
            NSMutableDictionary *updated = [conflict mutableCopy];
            updated[@"identity"] = identity;
            updated[@"token"] = NSUUID.UUID.UUIDString;
            self.renameConflicts[hash] = updated;
            [self.renameConflicts writeToFile:[self.configPath stringByAppendingPathComponent:@"rename-conflicts.plist"] atomically:YES];
        }
    }
}

- (NSDictionary *)dictionaryForTorrent:(tr_torrent *)torrent
{
    [self reconcileDataLocation:torrent];
    [self refreshRenameConflict:torrent];
    [self refreshPartialFileVisibility:torrent];
    tr_stat const stat = tr_torrentStat(torrent);
    tr_torrent_view const view = tr_torrentView(torrent);
    return @{
        @"id": @(stat.id),
        @"hashString": StringFromCString(view.hash_string),
        @"name": StringFromCString(view.name),
        @"status": @(stat.activity),
        @"renameConflict": self.renameConflicts[StringFromCString(view.hash_string)] ?: @{},
        @"error": (self.renameConflicts[StringFromCString(view.hash_string)] || self.dataLocationErrors[StringFromCString(view.hash_string)]) ? @3 : @(static_cast<int>(stat.error)),
        @"errorString": self.dataLocationErrors[StringFromCString(view.hash_string)] ?: StringFromView(stat.error_string),
        @"percentDone": @(stat.percent_done),
        @"doneDate": @(stat.done_date),
        @"metadataPercentComplete": @(stat.metadata_percent_complete),
        @"rateDownload": BytesPerSecond(stat.piece_download_speed),
        @"rateUpload": BytesPerSecond(stat.piece_upload_speed),
        @"sizeWhenDone": @(stat.size_when_done),
        @"leftUntilDone": @(stat.left_until_done),
        @"eta": @(stat.eta),
        @"uploadRatio": @(stat.upload_ratio),
        @"peersConnected": @(stat.peers_connected),
        @"downloadDir": StringFromView(tr_torrentGetDownloadDir(torrent)),
        @"bandwidthPriority": @(0),
        @"queuePosition": @(stat.queue_position),
        @"fileCount": @(tr_torrentFileCount(torrent))
    };
}

- (tr_torrent *)torrentForHash:(NSString *)hashString error:(NSError **)error
{
    if (![self ensureSession:error]) {
        return nullptr;
    }
    size_t const count = tr_sessionGetAllTorrents(self.session, nullptr, 0);
    std::vector<tr_torrent *> torrents(count);
    tr_sessionGetAllTorrents(self.session, torrents.data(), count);
    for (tr_torrent *torrent : torrents) {
        tr_torrent_view const view = tr_torrentView(torrent);
        if ([StringFromCString(view.hash_string) caseInsensitiveCompare:hashString] == NSOrderedSame) {
            return torrent;
        }
    }
    if (error != nullptr) {
        *error = GlassError(4, @"The selected local torrent no longer exists.");
    }
    return nullptr;
}

- (BOOL)applyToTorrents:(NSArray<NSString *> *)hashes
                  error:(NSError **)error
                 action:(void (^)(tr_torrent *torrent))action
{
    for (NSString *hashString in hashes) {
        tr_torrent *torrent = [self torrentForHash:hashString error:error];
        if (torrent == nullptr) {
            return NO;
        }
        action(torrent);
    }
    return YES;
}

- (BOOL)ensureSession:(NSError **)error
{
    if (self.session != nullptr) {
        return YES;
    }
    if (error != nullptr) {
        *error = GlassError(5, @"The local libtransmission session is not running.");
    }
    return NO;
}

static std::vector<tr_file_index_t> FileIndices(NSArray<NSNumber *> *numbers)
{
    std::vector<tr_file_index_t> files;
    files.reserve(numbers.count);
    for (NSNumber *number in numbers) {
        files.push_back(static_cast<tr_file_index_t>(number.unsignedIntValue));
    }
    return files;
}

@end
