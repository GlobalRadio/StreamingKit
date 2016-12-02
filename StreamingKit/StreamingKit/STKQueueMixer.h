//
//  STKQueueMixer.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>

typedef enum
{
    STKQueueMixerStateReady = 0,
    STKQueueMixerStateRunning = 1,
    STKQueueMixerStatePlaying = 2 | STKQueueMixerStateRunning,
    STKQueueMixerStatePaused = 4 | STKQueueMixerStateRunning,
    STKQueueMixerStateBuffering = 8 | STKQueueMixerStateRunning,
    STKQueueMixerStateStopped = 16,
    STKQueueMixerStateError = 32,
}
STKQueueMixerState;

@class STKQueueMixer;

// Equivalent of STKAudioPlayer's delegate methods
@protocol STKQueueMixerDelegate <NSObject>

/// Raised when an item has started playing
-(void) queue:(STKQueueMixer *)mixer didStartPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didSkipItemWithId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didFinishPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didChangeToState:(STKQueueMixerState)state from:(STKQueueMixerState)previousState;

@end


/*
 @class STKQueueMixer
 */
@interface STKQueueMixer : NSObject

@property (nonatomic, weak) id<STKQueueMixerDelegate> delegate;
@property (nonatomic) STKQueueMixerState mixerState;
@property (nonatomic, readonly) NSArray *mixerQueue;
@property (nonatomic) float volume;

// returns the amount of time played of the current track in seconds
@property (nonatomic, readonly) double progress;

- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID;
- (void)playNext:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor;
- (void)insertTrack:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor atIndex:(int) trackIndex;
- (void)replaceNext:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor;
- (void)replaceTrack:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor atIndex:(int) trackIndex;
- (void)queueURL:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor;
- (void)skipItemWithId:(NSString *)entryID;
- (void)stopPlayback:(BOOL)keepTrack;
- (void)startPlayback;


- (void)changeTrack:(NSString *)withID toUse:(NSURL *)newURL;

@end
