#import "LocalTransmissionBridge.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

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

    _configPath = configDirectory.path;
    _downloadPath = downloadDirectory.path;
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

    tr_ctor *ctor = tr_ctorNew(_session);
    tr_ctorSetPaused(ctor, TR_FORCE, false);
    tr_sessionLoadTorrents(_session, ctor);
    tr_ctorFree(ctor);

    return self;
}

- (void)dealloc
{
    if (_session != nullptr) {
        tr_sessionClose(_session);
        _session = nullptr;
    }
}

- (NSDictionary *)snapshotWithError:(NSError **)error
{
    if (![self ensureSession:error]) {
        return @{};
    }

    tr_session_stats const stats = tr_sessionGetStats(self.session);
    NSArray *torrents = [self torrentDictionaries];
    int64_t freeBytes = -1;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.downloadPath error:nil];
    NSNumber *freeSize = attributes[NSFileSystemFreeSize];
    if (freeSize != nil) {
        freeBytes = freeSize.longLongValue;
    }

    return @{
        @"stats": @{
            @"downloadSpeed": @(tr_sessionGetRawSpeed_KBps(self.session, tr_direction::Down) * 1000.0),
            @"uploadSpeed": @(tr_sessionGetRawSpeed_KBps(self.session, tr_direction::Up) * 1000.0),
            @"ratio": @(stats.ratio)
        },
        @"torrents": torrents,
        @"freeSpace": @{
            @"path": self.downloadPath,
            @"sizeBytes": @(freeBytes)
        }
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

- (BOOL)addMagnet:(NSString *)magnet downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error
{
    return [self addWithConfigure:^(tr_ctor *ctor) {
        return tr_ctorSetMetainfoFromMagnetLink(ctor, magnet.UTF8String);
    } downloadDirectory:downloadDirectory error:error];
}

- (BOOL)addTorrentData:(NSData *)data downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error
{
    return [self addWithConfigure:^(tr_ctor *ctor) {
        return tr_ctorSetMetainfo(ctor, static_cast<char const *>(data.bytes), data.length, nullptr);
    } downloadDirectory:downloadDirectory error:error];
}

- (BOOL)startTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error
{
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
    return [self applyToTorrents:hashes error:error action:^(tr_torrent *torrent) {
        tr_torrentRemove(torrent, deleteLocalData);
    }];
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

- (BOOL)renameTorrent:(NSString *)hashString path:(NSString *)path name:(NSString *)name error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }
    tr_torrentRenamePath(torrent, path.UTF8String, name.UTF8String, {});
    return YES;
}

- (BOOL)setWanted:(BOOL)wanted forTorrent:(NSString *)hashString fileIndices:(NSArray<NSNumber *> *)fileIndices error:(NSError **)error
{
    tr_torrent *torrent = [self torrentForHash:hashString error:error];
    if (torrent == nullptr) {
        return NO;
    }
    std::vector<tr_file_index_t> files = FileIndices(fileIndices);
    tr_torrentSetFileDLs(torrent, files.data(), static_cast<tr_file_index_t>(files.size()), wanted);
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
                   error:(NSError **)error
{
    if (![self ensureSession:error]) {
        return NO;
    }
    tr_ctor *ctor = tr_ctorNew(self.session);
    tr_ctorSetPaused(ctor, TR_FORCE, false);
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

- (NSDictionary *)dictionaryForTorrent:(tr_torrent *)torrent
{
    tr_stat const stat = tr_torrentStat(torrent);
    tr_torrent_view const view = tr_torrentView(torrent);
    return @{
        @"id": @(stat.id),
        @"hashString": StringFromCString(view.hash_string),
        @"name": StringFromCString(view.name),
        @"status": @(stat.activity),
        @"percentDone": @(stat.percent_done),
        @"rateDownload": BytesPerSecond(stat.piece_download_speed),
        @"rateUpload": BytesPerSecond(stat.piece_upload_speed),
        @"sizeWhenDone": @(stat.size_when_done),
        @"leftUntilDone": @(stat.left_until_done),
        @"eta": @(stat.eta),
        @"uploadRatio": @(stat.upload_ratio),
        @"peersConnected": @(stat.peers_connected),
        @"downloadDir": StringFromView(tr_torrentGetDownloadDir(torrent)),
        @"bandwidthPriority": @(0),
        @"queuePosition": @(stat.queue_position)
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
