#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocalTransmissionBridge : NSObject

- (nullable instancetype)initWithConfigDirectory:(NSURL *)configDirectory
                              downloadDirectory:(NSURL *)downloadDirectory
                                          error:(NSError **)error;

- (nullable NSDictionary *)snapshotWithError:(NSError **)error;
- (nullable NSString *)defaultDownloadDirectoryWithError:(NSError **)error;
- (nullable NSDictionary *)torrentDetailsForHash:(NSString *)hashString error:(NSError **)error;

- (BOOL)addMagnet:(NSString *)magnet downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error;
- (BOOL)addTorrentData:(NSData *)data downloadDirectory:(nullable NSString *)downloadDirectory error:(NSError **)error;
- (BOOL)startTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error;
- (BOOL)stopTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error;
- (BOOL)removeTorrents:(NSArray<NSString *> *)hashes deleteLocalData:(BOOL)deleteLocalData error:(NSError **)error;
- (BOOL)verifyTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error;
- (BOOL)reannounceTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error;
- (BOOL)moveTorrents:(NSArray<NSString *> *)hashes toQueuePosition:(NSInteger)queuePosition error:(NSError **)error;
- (BOOL)moveDataForTorrent:(NSString *)hashString toDownloadDirectory:(NSString *)downloadDirectory error:(NSError **)error;
- (BOOL)renameTorrent:(NSString *)hashString path:(NSString *)path name:(NSString *)name error:(NSError **)error;
- (BOOL)setWanted:(BOOL)wanted forTorrent:(NSString *)hashString fileIndices:(NSArray<NSNumber *> *)fileIndices error:(NSError **)error;
- (BOOL)setPriority:(NSInteger)priority forTorrent:(NSString *)hashString fileIndices:(NSArray<NSNumber *> *)fileIndices error:(NSError **)error;
- (BOOL)setPriority:(NSInteger)priority forTorrents:(NSArray<NSString *> *)hashes error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
