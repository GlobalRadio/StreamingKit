//
//  STKQueueMixer.m
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <pthread/pthread.h>
#import "NSMutableArray+STKAudioPlayer.h"
#import "STKAudioPlayer.h"
#import "STKDataSource.h"
#import "STKMixableQueueEntry.h"
#import "STKQueueMixer.h"


typedef enum
{
    BUS_0 = 0,
    BUS_1 = 1,
    FADE_FROM_0,
    FADE_FROM_1
} BUS_STATE;


@interface STKQueueMixer() {
    
    AUGraph _audioGraph;
    
    AUNode _mixerNode;
    AUNode _outputNode;
    
    AudioComponentInstance _mixerUnit;
    AudioComponentInstance _outputUnit;
    
    AudioComponentDescription _mixerDescription;
    AudioComponentDescription _outputDescription;
    
    AudioStreamBasicDescription _outputStreamDescription;
    
    NSMutableArray *_mixQueue;
    STKMixableQueueEntry *_mixBus0;
    STKMixableQueueEntry *_mixBus1;
    
    BOOL _startingPlay;
    BUS_STATE _busState;
    
    pthread_mutex_t _playerMutex;
    
    UInt64 _framesToContinueAfterBuffer;
}

@end

// To handle sleep screen playback, we need to set all non-I/O audio units to this size.
const UInt32 k_maxFramesPerSlice = 4096;
const UInt32 k_busCount = 2;
const UInt32 k_bytesPerSample = 2;
const Float64 k_graphSampleRate = 44100.0;
const Float64 k_samplesPerMs = 44.1;
const UInt64 k_framesRequiredToPlay = k_graphSampleRate * 5;
const int k_maxLoadingEntries = 5;


@implementation STKQueueMixer

- (instancetype)init
{
    self = super.init;
    if (nil != self)
    {
        self.volume = 1;
        self.mixerState = STKQueueMixerStateReady;
        
        _mixQueue = [[NSMutableArray alloc] init];
        _startingPlay = YES;
        _busState = BUS_0;
        
        _framesToContinueAfterBuffer = k_framesRequiredToPlay;
        
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_playerMutex, &attr);
        
        _outputStreamDescription = (AudioStreamBasicDescription)
        {
            .mSampleRate = 44100.00,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            .mFramesPerPacket = 1,
            .mChannelsPerFrame = 2,
            .mBytesPerFrame = k_bytesPerSample * 2 /*channelsPerFrame*/,
            .mBitsPerChannel = 8 * k_bytesPerSample,
            .mBytesPerPacket = (k_bytesPerSample * 2)
        };
        
        [self buildAudioGraph];
        [self startPlayback];
    }
    
    return self;
}


#pragma mark Audio Graph magic

/*
                            +---------------+                 __
 -- BUS 0 (Now Playing) --> |               |                / //
                            | Mixer Unit    | --- lpcm ---> | ( -
 -- BUS 1 (Next up)     --> |               |                \_\\
                            +---------------+
 
 BUS 1 will be disabled and silenced until we reach the set time in the track to start the merge.
 At this time, BUS1 will be faded in and BUS0 faded out. For mixing the next song in, we'll then
 switch the fade from BUS1 to BUS0.
 
 */
- (void)buildAudioGraph
{
    // TODO: Safety checking on creation etc
    NewAUGraph(&_audioGraph);
    AUGraphOpen(_audioGraph);
    
    // Mixer with 2 input busses
    _mixerDescription = (AudioComponentDescription) {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AUGraphAddNode(_audioGraph, &_mixerDescription, &_mixerNode);
    AUGraphNodeInfo(_audioGraph, _mixerNode, &_mixerDescription, &_mixerUnit);
    
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &k_busCount, sizeof(k_busCount));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &k_maxFramesPerSlice, sizeof(k_maxFramesPerSlice));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &k_graphSampleRate, sizeof(k_graphSampleRate));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    // Hook up render callback - will need to do for both bus inputs when we're mixing
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = OutputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;
    
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 0, &callbackStruct);
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 1, &callbackStruct);
    
    // Output to hardware
    _outputDescription = (AudioComponentDescription) {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AUGraphAddNode(_audioGraph, &_outputDescription, &_outputNode);
    AUGraphNodeInfo(_audioGraph, _outputNode, &_outputDescription, &_outputUnit);
    AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    AUGraphConnectNodeInput(_audioGraph, _mixerNode, 0, _outputNode, 0);
    
    AUGraphInitialize(_audioGraph);
    
    // Set input of non-playing input bus to 0, as default is 1 and we don't want an unbalanced initial track volume...
    float busChannel = 1;                   // We're silencing channel 1, as we start with bus 0.
    float busVolume = 0;                    // Set volume to 0.
    float frameOffset = 0;                  // Make the change instantly
    AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busChannel, busVolume, frameOffset);
}

static OSStatus OutputRenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
    OSStatus error = 0;
    STKQueueMixer *player = (__bridge STKQueueMixer *)inRefCon;
    
    // Determining what bus we're pulling from and what the volume should be.
    if (inBusNumber != player->_busState && FADE_FROM_0 > player->_busState) {
        return error;
    }
    
    STKMixableQueueEntry *entryForBus = (BUS_0 == inBusNumber) ? player->_mixBus0 : player->_mixBus1;
    if (nil == entryForBus)
    {
        return error;
    }
    
    // Use array of entries and then use the bus number to index the correct entry
    UInt32 bytesPerFrame = entryForBus->audioStreamBasicDescription.mBytesPerFrame;
    
    ioData->mBuffers[0].mNumberChannels = entryForBus->audioStreamBasicDescription.mChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize = inNumberFrames * bytesPerFrame;
    
    float fadeValue = (entryForBus->framesPlayed - entryForBus->_fadeFrom) * entryForBus->_fadeRatio;
    float volume = 0;
    if (BUS_0 == inBusNumber)
    {
        if (BUS_0 == player->_busState || FADE_FROM_0 == player->_busState)
        {
            volume = MAX(MIN(1.0 - fadeValue, 1.0), 0);
            if (0 >= volume) {
                [player trackEntry:entryForBus finishedPlayingOnBus:BUS_0];
            }
        }
        else if (FADE_FROM_1 == player->_busState)
        {
            volume = 1;
        }
    }
    else
    {
        if (BUS_1 == player->_busState || FADE_FROM_1 == player->_busState)
        {
            volume = MAX(MIN(1.0 - fadeValue, 1.0), 0);
            if (0 >= volume) {
                [player trackEntry:entryForBus finishedPlayingOnBus:BUS_1];
            }
        }
        else if (FADE_FROM_0 == player->_busState)
        {
            volume = 1;
        }
    }
    
    if (1 > volume && inBusNumber == player->_busState)
    {
        player->_busState = (player->_busState == BUS_0) ? FADE_FROM_0 : FADE_FROM_1;
    }
    
    // Here, the 0 is frame offset, which when 0 will make the change straight away.
    error = AudioUnitSetParameter(player->_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, inBusNumber, volume, 0);
    
    // Push data to hardware and update where to place data    
    AudioBuffer* audioBuffer = entryForBus->_pcmAudioBuffer;
    UInt32 totalFramesCopied = 0;
    UInt32 frameSizeInBytes = entryForBus->_pcmBufferFrameSizeInBytes;
    UInt32 used = entryForBus->_pcmBufferUsedFrameCount;
    UInt32 start = entryForBus->_pcmBufferFrameStartIndex;
    UInt32 end = (entryForBus->_pcmBufferFrameStartIndex + entryForBus->_pcmBufferUsedFrameCount) % entryForBus->_pcmBufferTotalFrameCount;
    
    BOOL bufferIsReady = YES;
    BOOL fileFinishedEarly = NO;
    
    if (STKQueueMixerStateBuffering == player.mixerState) {
        if ((entryForBus->framesPlayed + entryForBus->_pcmBufferUsedFrameCount) < player->_framesToContinueAfterBuffer) {
            
            bufferIsReady = NO;
        }
    } else if (STKQueueMixerStateReady == player.mixerState) {
        if ((entryForBus->framesQueued - entryForBus->framesPlayed) < k_framesRequiredToPlay) {
            
            bufferIsReady = NO;
        }
    } else if (ABS(entryForBus->lastFrameQueued - entryForBus->framesPlayed) <= inNumberFrames && !entryForBus.dataSource.hasBytesAvailable) {
        
        fileFinishedEarly = YES;
        
    } else if (entryForBus->_pcmBufferUsedFrameCount <= inNumberFrames) {
    
        bufferIsReady = NO;
    }
    
    if (bufferIsReady)
    {
        player.mixerState = STKQueueMixerStatePlaying;
        
        if (end > start)
        {
            UInt32 framesToCopy = MIN(inNumberFrames, used);
            
            ioData->mBuffers[0].mNumberChannels = 2;
            ioData->mBuffers[0].mDataByteSize = frameSizeInBytes * framesToCopy;
            
            memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);
            totalFramesCopied = framesToCopy;
            
            OSSpinLockLock(&entryForBus->spinLock);
            entryForBus->_pcmBufferFrameStartIndex = (entryForBus->_pcmBufferFrameStartIndex + totalFramesCopied) % entryForBus->_pcmBufferTotalFrameCount;
            entryForBus->framesPlayed += MIN(inNumberFrames, entryForBus->_pcmBufferUsedFrameCount);
            entryForBus->_pcmBufferUsedFrameCount -= totalFramesCopied;
            OSSpinLockUnlock(&entryForBus->spinLock);
        }
        else
        {
            UInt32 framesToCopy = MIN(inNumberFrames, entryForBus->_pcmBufferTotalFrameCount - start);
            
            ioData->mBuffers[0].mNumberChannels = 2;
            ioData->mBuffers[0].mDataByteSize = frameSizeInBytes * framesToCopy;
            
            memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);

            UInt32 moreFramesToCopy = 0;
            UInt32 delta = inNumberFrames - framesToCopy;
            
            if (delta > 0)
            {
                moreFramesToCopy = MIN(delta, end);
                
                ioData->mBuffers[0].mNumberChannels = 2;
                ioData->mBuffers[0].mDataByteSize += frameSizeInBytes * moreFramesToCopy;
                
                memcpy(ioData->mBuffers[0].mData + (framesToCopy * frameSizeInBytes), audioBuffer->mData, frameSizeInBytes * moreFramesToCopy);
            }
            
            totalFramesCopied = framesToCopy + moreFramesToCopy;
            
            OSSpinLockLock(&entryForBus->spinLock);
            entryForBus->_pcmBufferFrameStartIndex = (entryForBus->_pcmBufferFrameStartIndex + totalFramesCopied) % entryForBus->_pcmBufferTotalFrameCount;
            entryForBus->framesPlayed += MIN(inNumberFrames, entryForBus->_pcmBufferUsedFrameCount);
            entryForBus->_pcmBufferUsedFrameCount -= totalFramesCopied;
            OSSpinLockUnlock(&entryForBus->spinLock);
        }
        
        [entryForBus continueBuffering];
    }
    else
    {
        player.mixerState = STKQueueMixerStateBuffering;
        player->_framesToContinueAfterBuffer = entryForBus->framesPlayed + k_framesRequiredToPlay;
        
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        return error;
    }
    
    if (totalFramesCopied < inNumberFrames)
    {
        player.mixerState = STKQueueMixerStateBuffering;
        player->_framesToContinueAfterBuffer = entryForBus->framesQueued + k_framesRequiredToPlay;
        
        UInt32 delta = inNumberFrames - totalFramesCopied;
        memset(ioData->mBuffers[0].mData + (totalFramesCopied * frameSizeInBytes), 0, delta * frameSizeInBytes);
        
        if (fileFinishedEarly) {
            
            // File finished, but was smaller that it reported.
            player.mixerState = STKQueueMixerStatePlaying;
        }
    }
    
    if (entryForBus->framesPlayed == entryForBus->lastFrameQueued)
    {
        [player trackEntry:entryForBus finishedPlayingOnBus:inBusNumber];
    }
    
    return error;
}


/*
 @brief Stop or pause playback. 
 
 @param keepTrack should be set to YES if we are pausing playback. If set to NO, buffer and queue will be cleared.
 
 @return void
 */
- (void)stopPlayback:(BOOL)keepTrack
{
    AUGraphStop(_audioGraph);
    
    if (keepTrack) {
        self.mixerState = STKQueueMixerStatePaused;
    } else {
        self.mixerState = STKQueueMixerStateStopped;
        [self clearQueue];
    }
}

- (void)startPlayback
{
    self.mixerState = STKQueueMixerStatePlaying;
    
    Boolean graphIsRunning;
    AUGraphIsRunning(_audioGraph, &graphIsRunning);
    if (graphIsRunning) {
        return;
    }
    
    AUGraphUninitialize(_audioGraph);
    AUGraphInitialize(_audioGraph);
    
    AUGraphStart(_audioGraph);
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0);
}

#pragma mark Properties

- (double)progress {
    STKMixableQueueEntry *nowPlaying = (BUS_0 == _busState || FADE_FROM_1 == _busState) ? _mixBus0 : _mixBus1;
    
    if (nowPlaying == nil) {
        return 0;
    }
    
    OSSpinLockLock(&nowPlaying->spinLock);
    double retval = nowPlaying->seekTime + (nowPlaying->framesPlayed / k_graphSampleRate);
    OSSpinLockUnlock(&nowPlaying->spinLock);
    
    return retval;
}


/*
 @brief Set and alert mixer state if passed state is different to the current state
 
 @param toState
 
 @return void
 */
- (void)setMixerState:(STKQueueMixerState)toState {
    
    if (_mixerState != toState) {
        STKQueueMixerState fromState = _mixerState;
        _mixerState = toState;
        
        [self.delegate queue:self didChangeToState:toState from:fromState];
    }
}


#pragma mark Queue management

/*
 @brief Get the mixer queue, including the now playing and next track
 */
- (NSArray *)mixerQueue
{
    NSMutableArray *queueArray = @[];
    if (nil != _mixBus0) {
        [queueArray addObjectsFromArray:_mixBus0];
    }
    
    if (nil != _mixBus1) {
        [queueArray addObjectsFromArray:_mixBus1];
    }
    
    if (nil != _mixBus1) {
        [queueArray addObjectsFromArray:_mixQueue];
    }
    
    return queueArray;
}

/*
 @brief Queue source to back of queue
 
 @param url to play
 @param trackID to use for identifying entry
 @param totalTime of the tack
 @param crossfade time before end of file to start fade in ms.
 @param fadeFor time in ms
 
 @return void
 */
- (void)queueURL:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor
{
    STKMixableQueueEntry *mixableEntry = [self entryForURL:url withID:trackID trackLength:totalTime fadeAt:crossfade fadeTime:fadeFor];
    [_mixQueue enqueue:mixableEntry];
    
    [self updateQueue];
    [self loadTracks];
    
    if (!(self.mixerState & STKQueueMixerStateRunning)) {
        [self startPlayback];
    }
}

/*
 @brief Queue a URL to be played as soon as possible; place as next up bus entry and put current next up
        entry back to the front of the queue.
 
 @param url to play
 @param trackID to use for identifying entry
 @param totalTime of the tack
 @param crossfade time before end of file to start fade in ms.
 @param fadeFor time in ms
 
 @return void
 */
- (void)playNext:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor
{
    STKMixableQueueEntry *pushingEntry = [self entryForURL:url withID:trackID trackLength:totalTime fadeAt:crossfade fadeTime:fadeFor];
    [pushingEntry beginEntryLoad];
    
    STKMixableQueueEntry *bargedEntry = [self replaceNextUpWithEntry:pushingEntry];
    if (nil != bargedEntry) {
        pthread_mutex_lock(&_playerMutex);
        [_mixQueue addObject:bargedEntry];
        pthread_mutex_unlock(&_playerMutex);
    }
}

/*
 @brief Queue a URL to be played at the specified index; place as next up bus entry and put current next up
 entry back to the front of the queue.
 
 @param url to play
 @param trackID to use for identifying entry
 @param totalTime of the tack
 @param crossfade time before end of file to start fade in ms.
 @param fadeFor time in ms
 @param trackIndex order of the track
 
 @return void
 */
- (void)insertTrack:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor atIndex:(int) trackIndex
{
    STKMixableQueueEntry *pushingEntry = [self entryForURL:url withID:trackID trackLength:totalTime fadeAt:crossfade fadeTime:fadeFor];
    [pushingEntry beginEntryLoad];
    
    pthread_mutex_lock(&_playerMutex);
    [_mixQueue insertObject:pushingEntry atIndex:_mixQueue.count + 1 - trackIndex];
    pthread_mutex_unlock(&_playerMutex);
}

/*
 @brief Queue a URL to be played as soon as possible, replacing current next up entry.
 
 @param url to play
 @param trackID to use for identifying entry
 @param totalTime of the tack
 @param crossfade time before end of file to start fade in ms.
 @param fadeFor time in ms
 
 @return void
 */
- (void)replaceNext:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor
{
    STKMixableQueueEntry *replacingEntry = [self entryForURL:url withID:trackID trackLength:totalTime fadeAt:crossfade fadeTime:fadeFor];
    [replacingEntry beginEntryLoad];
    
    STKMixableQueueEntry *bargedEntry = [self replaceNextUpWithEntry:replacingEntry];
    if (nil != bargedEntry) {
        
        [bargedEntry tidyUp];
        bargedEntry = nil;
    }
}

/*
 @brief Queue a URL to be played at the specified index, replacing the entry at that index.
 
 @param url to play
 @param trackID to use for identifying entry
 @param totalTime of the tack
 @param crossfade time before end of file to start fade in ms.
 @param fadeFor time in ms
 @param trackIndex order of the track
 
 @return void
 */
- (void)replaceTrack:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor atIndex:(int) trackIndex
{
    STKMixableQueueEntry *replacingEntry = [self entryForURL:url withID:trackID trackLength:totalTime fadeAt:crossfade fadeTime:fadeFor];
    [replacingEntry beginEntryLoad];
    
    STKMixableQueueEntry *bargedEntry = [_mixQueue objectAtIndex:trackIndex];
    
    pthread_mutex_lock(&_playerMutex);
    [_mixQueue replaceObjectAtIndex:_mixQueue.count + 1 - trackIndex withObject:replacingEntry];
    pthread_mutex_unlock(&_playerMutex);
    
    
    if (nil != bargedEntry) {
        
        [bargedEntry tidyUp];
        bargedEntry = nil;
    }
}

/*
 @brief Replace the next up entry with the passed entry.
 
 @param replaceWith will be used in place of the currently next up track.
 
 @return reference to the entry that was replaced.
 */
- (STKMixableQueueEntry *)replaceNextUpWithEntry:(STKMixableQueueEntry *)replaceWith
{
    STKMixableQueueEntry *replacedEntry;
    if (BUS_0 == _busState || FADE_FROM_0 == _busState)
    {
        // Next up is bus 1, so insert our queue-jumper here and place the currently up next entry to front of queue
        replacedEntry = _mixBus1;
        _mixBus1 = replaceWith;
    }
    else
    {
        replacedEntry = _mixBus0;
        _mixBus0 = replaceWith;
    }
    
    return replacedEntry;
}


- (STKMixableQueueEntry *)entryForURL:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor
{
    STKDataSource *source = [STKAudioPlayer dataSourceWithChangableURLFromInitialURL:url];
    STKMixableQueueEntry *mixableEntry = [[STKMixableQueueEntry alloc] initWithDataSource:source andQueueItemId:trackID];
    [mixableEntry setFadeoutAt:(crossfade * k_samplesPerMs) overDuration:(fadeFor * k_samplesPerMs) trackDuration:(totalTime * k_samplesPerMs)];
    
    return mixableEntry;
}


- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID
{
    pthread_mutex_lock(&_playerMutex);
    NSArray *currentQueue = _mixQueue.copy;
    pthread_mutex_unlock(&_playerMutex);
    
    for (STKMixableQueueEntry *entry in currentQueue)
    {
        if ([itemID isEqualToString:(NSString *)entry.queueItemId])
        {
            return YES;
        }
    }
    
    if ([itemID isEqualToString:(NSString *)_mixBus0.queueItemId])
    {
        return YES;
    }
    
    if ([itemID isEqualToString:(NSString *)_mixBus1.queueItemId])
    {
        return YES;
    }
    
    return NO;
}


- (void)skipItemWithId:(NSString *)entryID
{
    STKMixableQueueEntry *skippedEntry = [self entryForID:entryID];
    if (nil == skippedEntry)
    {
        return;
    }
    
    STKMixableQueueEntry *nextUp = (BUS_0 == _busState) ? _mixBus1 : _mixBus0;
    STKMixableQueueEntry *nowPlaying = (BUS_0 == _busState) ? _mixBus0 : _mixBus1;
    
    // If we're skipping the next up track, we need to do something special...
    if (nextUp == skippedEntry)
    {
        pthread_mutex_lock(&_playerMutex);
        STKMixableQueueEntry *newNextUp = _mixQueue.dequeue;
        pthread_mutex_unlock(&_playerMutex);
        
        if (BUS_0 == _busState || FADE_FROM_0 == _busState) {
            _mixBus1 = newNextUp;
        } else {
            _mixBus0 = newNextUp;
        }
        
        [skippedEntry tidyUp];
    }
    else if (nowPlaying != skippedEntry)
    {
        // If we're skipping something from the track, we don't need to worry too much...
        pthread_mutex_lock(&_playerMutex);
        [_mixQueue removeObject:skippedEntry];
        [skippedEntry tidyUp];
        pthread_mutex_unlock(&_playerMutex);
        
        return;
    }
    else
    {
        // ...however, if we're skipping the now playing entry, we need to do something now.
        switch (_busState)
        {
            case BUS_0:
                _busState = FADE_FROM_0;
                [skippedEntry fadeFromNow];
                break;
                
            case BUS_1:
                _busState = FADE_FROM_1;
                [skippedEntry fadeFromNow];
                break;
                
            case FADE_FROM_0:
                [self trackEntry:_mixBus0 finishedPlayingOnBus:BUS_0];
                [skippedEntry fadeFromNow];
                _busState = FADE_FROM_1;
                break;
                
            case FADE_FROM_1:
                [self trackEntry:_mixBus1 finishedPlayingOnBus:BUS_1];
                [skippedEntry fadeFromNow];
                _busState = FADE_FROM_0;
                break;
                
            default:
                NSAssert(NO, @"Unexpected bus state found when skipping queue entry with ID %@.", entryID);
                break;
        }
    }
    
    [self.delegate queue:self didSkipItemWithId:skippedEntry.queueItemId];
    [self loadTracks];
}


- (STKMixableQueueEntry *)entryForID:(NSString *)entryID
{
    if ([entryID isEqualToString:(NSString *)_mixBus0.queueItemId]) {
        return _mixBus0;
    }

    if ([entryID isEqualToString:(NSString *)_mixBus1.queueItemId]) {
        return _mixBus1;
    }
    
    for (STKMixableQueueEntry *entry in _mixQueue) {
        if ([entryID isEqualToString:(NSString *)entry.queueItemId]) {
            return entry;
        }
    }
    
    return nil;
}


- (void)trackEntry:(STKMixableQueueEntry *)entry finishedPlayingOnBus:(int)busNumber
{
    // Ensure bus is set to 0 volume
    AudioUnitSetParameter (_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, 0, 0);
    
    [_mixQueue removeObject:entry];
    [self.delegate queue:self didFinishPlayingQueueItemId:entry.queueItemId];
    
    STKMixableQueueEntry *nowPlaying;
    if (0 == busNumber)
    {
        _busState = BUS_1;
        _mixBus0 = nil;
        nowPlaying = _mixBus1;
    }
    else
    {
        _busState = BUS_0;
        _mixBus1 = nil;
        nowPlaying = _mixBus0;
    }
    
    [self.delegate queue:self didStartPlayingQueueItemId:nowPlaying];
    [self updateQueue];
    [self loadTracks];
    
    [entry tidyUp];
}


- (void)updateQueue
{
    if (nil != _mixBus0 && nil != _mixBus1)
    {
        // Both tracks currently full, so no need to do anything
        return;
    }
    
    STKMixableQueueEntry *nextUp = _mixQueue.dequeue;
    if (nil == nextUp)
    {
        return;
    }
    
    // Should already be loading, but it is possible to reach a track before it has started loading.
    [nextUp beginEntryLoad];
    
    if (_startingPlay)
    {
        _mixBus0 = nextUp;
        _startingPlay = NO;
        return;
    }
    
    if (BUS_0 == _busState)
    {
        _mixBus1 = nextUp;
    }
    else
    {
        _mixBus0 = nextUp;
    }
}


- (void)loadTracks
{
    int queueSize = (int)_mixQueue.count;
    for (int entryIndex = queueSize - 1; entryIndex > MAX((queueSize - k_maxLoadingEntries), 0); --entryIndex)
    {
        [_mixQueue[entryIndex] beginEntryLoad];
    }
}


- (void)changeTrack:(NSString *)withID toUse:(NSURL *)newURL {
    
    STKMixableQueueEntry *entryToChange = [self entryForID:withID];
    [entryToChange changeToURL:newURL];
}


#pragma mark Tidy up


- (void)clearQueue
{
    [_mixBus0 tidyUp];
    [_mixBus1 tidyUp];
    
    _mixBus0 = nil;
    _mixBus1 = nil;
    
    pthread_mutex_lock(&_playerMutex);
    
    for (STKMixableQueueEntry *entry in _mixQueue) {
        [entry tidyUp];
    }
    
    [_mixQueue removeAllObjects];
    
    pthread_mutex_unlock(&_playerMutex);
    
    _startingPlay = YES;
    _busState = BUS_0;
    
    self.volume = 1;
}


- (void)dealloc
{
    [self clearQueue];
    
    if (_audioGraph)
    {
        AUGraphStop(_audioGraph);
        AUGraphUninitialize(_audioGraph);
        AUGraphClose(_audioGraph);
        DisposeAUGraph(_audioGraph);
    }
    
    pthread_mutex_destroy(&_playerMutex);
}

@end
