//
//  STKMixableQueueEntry.m
//  StreamingKit
//
//  Created by James Gordon on 09/12/2014.
//

#import <pthread/pthread.h>
#import "STKConstants.h"
#import "STKAutoRecoveringHTTPDataSource.h"
#import "STKAdaptiveURLHTTPDataSource.h"
#import "STKMixableQueueEntry.h"

static AudioStreamBasicDescription canonicalAudioStreamBasicDescription;
const int k_readBufferSize = 64 * 1024;

@interface STKMixableQueueEntry() {
    
    OSSpinLock _internalStateLock;
    
    UInt32 _readBufferSize;
    UInt8 *_readBuffer;
    SInt64 _totalBytesRead;
    AudioBufferList _pcmAudioBufferList;
    
    NSThread *_playbackThread;
    NSRunLoop *_playbackThreadRunLoop;
    pthread_mutex_t _entryMutex;
    pthread_cond_t _playerThreadReadyCondition;
    
    AudioFileStreamID _fileStream;
    AudioConverterRef _audioConverter;
    AudioStreamBasicDescription _audioConverterAudioStreamBasicDescription;
    
    UInt32 _bytesPerSample;
    UInt32 _channelsPerFrame;
    
    BOOL _discontinuousData;
    BOOL _continueRunLoop;
}

@property (nonatomic, readonly) BOOL isLoading;

@end


@implementation STKMixableQueueEntry

- (instancetype)initWithDataSource:(STKDataSource *)dataSource andQueueItemId:(NSObject *)queueItemId
{
    self = [super initWithDataSource:dataSource andQueueItemId:queueItemId];
    if (nil != self)
    {
        _isLoading = NO;
        _discontinuousData = NO;
        _continueRunLoop = YES;
        _waiting = NO;
        
        _bytesPerSample = 2;
        _channelsPerFrame = 2;
        
        canonicalAudioStreamBasicDescription = (AudioStreamBasicDescription)
        {
            .mSampleRate = 44100.00,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            .mFramesPerPacket = 1,
            .mChannelsPerFrame = 2,
            .mBytesPerFrame = _bytesPerSample * _channelsPerFrame,
            .mBitsPerChannel = 8 * _bytesPerSample,
            .mBytesPerPacket = _bytesPerSample * _channelsPerFrame
        };
        
        _readBuffer = calloc(sizeof(UInt8), k_readBufferSize);
        _pcmAudioBuffer = &_pcmAudioBufferList.mBuffers[0];
        
        _pcmAudioBufferList.mNumberBuffers = 1;
        _pcmAudioBufferList.mBuffers[0].mDataByteSize = (canonicalAudioStreamBasicDescription.mSampleRate * STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS) * canonicalAudioStreamBasicDescription.mBytesPerFrame;
        _pcmAudioBufferList.mBuffers[0].mData = (void*)calloc(_pcmAudioBuffer->mDataByteSize, 1);
        _pcmAudioBufferList.mBuffers[0].mNumberChannels = 2;
        
        _pcmBufferFrameSizeInBytes = canonicalAudioStreamBasicDescription.mBytesPerFrame;
        _pcmBufferTotalFrameCount = _pcmAudioBuffer->mDataByteSize / _pcmBufferFrameSizeInBytes;
        
        [self startPlaybackThread];
    }
    
    return self;
}


- (void)setFadeoutAt:(Float64)fadeFrame overDuration:(Float64)fadeForFrames trackDuration:(Float64)totalFrames
{
    NSAssert(0 != fadeForFrames, @"Parameter fadeForFrames is 0. This is causing a divide by zero.");
    
    pthread_mutex_lock(&_entryMutex);
    _fadeFrom = totalFrames - fadeFrame;
    _fadeRatio = 1 / fadeForFrames;
    pthread_mutex_unlock(&_entryMutex);
}

- (void)fadeFromNow
{
    pthread_mutex_lock(&_entryMutex);
    _fadeFrom = self->framesPlayed;
    pthread_mutex_unlock(&_entryMutex);
}


/*
 @brief Start load of the entry and register for data-related events
 
 @param runLoop on which to process entry data
 
 @return void
 */
- (void)beginEntryLoad
{
    [self loadEntryWithOffset:0];
}


- (void)loadEntryWithOffset:(SInt64)offset {
    
    if (YES == self.isLoading)
    {
        return;
    }
    
    _isLoading = YES;
    self.dataSource.delegate = self;
    
    while (nil == _playbackThreadRunLoop)
    {
        [NSThread sleepForTimeInterval:0.01];
    }
    
    [self.dataSource registerForEvents:_playbackThreadRunLoop];
    [self invokeOnPlaybackThread:^ {
        [self.dataSource seekToOffset:offset];
    }];
}


- (void)changeToURL:(NSURL *)url {
    
    
    [self invokeOnPlaybackThread:^{
        [self.dataSource unregisterForEvents];
        [self.dataSource close];
        
        STKAutoRecoveringHTTPDataSource *recoveringDataSource = ((STKAutoRecoveringHTTPDataSource *)self.dataSource);
        [((STKAdaptiveURLHTTPDataSource *)recoveringDataSource.innerDataSource) switchToURL:url];
        
        // If the entry is already in the loading state, start load with new URL now.
        if (self.isLoading) {
            
            _isLoading = NO;
            [self loadEntryWithOffset:_totalBytesRead];
        }

    }];
}


#pragma mark Data Source Delegate

-(void) dataSourceDataAvailable:(STKDataSource*)dataSourceIn
{
    OSStatus error;
    
    if (self.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (!self.dataSource.hasBytesAvailable)
    {
        return;
    }
    
    int read = [self.dataSource readIntoBuffer:_readBuffer withSize:k_readBufferSize];
    if (read == 0)
    {
        return;
    }
    
    // Keeping track of this so that we know where to resume from when changing URL.
    _totalBytesRead += read;
    
    if (_fileStream == 0)
    {
        error = AudioFileStreamOpen((__bridge void*)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, dataSourceIn.audioFileTypeHint, &_fileStream);
        if (error)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
    
    if (read < 0)
    {
        // iOS will shutdown network connections if the app is backgrounded (i.e. device is locked when player is paused)
        // We try to reopen -- should probably add a back-off protocol in the future
        
        SInt64 position = self.dataSource.position;
        [self.dataSource seekToOffset:position];
        
        return;
    }
    
    int flags = 0;
    if (_discontinuousData)
    {
        flags = kAudioFileStreamParseFlag_Discontinuity;
    }

    if (_fileStream)
    {
        error = AudioFileStreamParseBytes(_fileStream, read, _readBuffer, flags);
        if (error)
        {
            AudioFileStreamClose(_fileStream);
            _fileStream = nil;
            
            return;
        }
    }
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSource
{
    NSLog(@"I'm probably going to crash; data source error");
}

-(void) dataSourceEof:(STKDataSource*)dataSource
{
    OSSpinLockLock(&_internalStateLock);
    self->lastFrameQueued = self->framesQueued;
    OSSpinLockUnlock(&_internalStateLock);
    
    self.dataSource.delegate = nil;
    [self.dataSource unregisterForEvents];
    [self.dataSource close];
}



#pragma mark Audio Converter management


BOOL GetHardwareCodecClassDesc(UInt32 formatId, AudioClassDescription* classDesc)
{
#if TARGET_OS_IPHONE
    UInt32 size;
    
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size) != 0)
    {
        return NO;
    }
    
    UInt32 decoderCount = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[decoderCount];
    
    if (AudioFormatGetProperty(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size, encoderDescriptions) != 0)
    {
        return NO;
    }
    
    for (UInt32 i = 0; i < decoderCount; ++i)
    {
        if (encoderDescriptions[i].mManufacturer == kAppleHardwareAudioCodecManufacturer)
        {
            *classDesc = encoderDescriptions[i];
            return YES;
        }
    }
#endif
    
    return NO;
}

-(void) destroyAudioConverter
{
    if (_audioConverter)
    {
        AudioConverterDispose(_audioConverter);
        _audioConverter = nil;
    }
}

-(void) createAudioConverter:(AudioStreamBasicDescription*)asbd
{
    OSStatus status;
    Boolean writable;
    UInt32 cookieSize = 0;
    
    if (memcmp(asbd, &_audioConverterAudioStreamBasicDescription, sizeof(AudioStreamBasicDescription)) == 0)
    {
        AudioConverterReset(_audioConverter);
        return;
    }
    
    [self destroyAudioConverter];
    
    AudioClassDescription classDesc;
    
    if (GetHardwareCodecClassDesc(asbd->mFormatID, &classDesc))
    {
        AudioConverterNewSpecific(asbd, &canonicalAudioStreamBasicDescription, 1,  &classDesc, &_audioConverter);
    }
    
    if (!_audioConverter)
    {
        status = AudioConverterNew(asbd, &canonicalAudioStreamBasicDescription, &_audioConverter);
        
        if (status)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
    
    _audioConverterAudioStreamBasicDescription = *asbd;
    
    if (self.dataSource.audioFileTypeHint != kAudioFileAAC_ADTSType)
    {
        status = AudioFileStreamGetPropertyInfo(_fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
        if (status)
        {
            return;
        }
        
        void* cookieData = alloca(cookieSize);

        status = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        if (status)
        {
            return;
        }
        
        status = AudioConverterSetProperty(_audioConverter, kAudioConverterDecompressionMagicCookie, cookieSize, &cookieData);
        if (status)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
}


OSStatus EntryAudioConverterCallback(AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription **outDataPacketDescription, void* inUserData)
{
    AudioConvertInfo* convertInfo = (AudioConvertInfo*)inUserData;
    if (convertInfo->done)
    {
        ioNumberDataPackets = 0;
        return 100;
    }
    
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = convertInfo->audioBuffer;
    
    if (outDataPacketDescription)
    {
        *outDataPacketDescription = convertInfo->packetDescriptions;
    }
    
    *ioNumberDataPackets = convertInfo->numberOfPackets;
    convertInfo->done = YES;
    
    return 0;
}

#pragma mark Audio stream parsing

void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
    STKMixableQueueEntry *entry = (__bridge STKMixableQueueEntry *)clientData;
    [entry handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
    OSStatus error;
    
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            self->parsedHeader = YES;
            self->audioDataOffset = offset;
            
            if (0 == self->audioStreamBasicDescription.mBytesPerFrame) {
                self->audioStreamBasicDescription.mBytesPerFrame = canonicalAudioStreamBasicDescription.mBytesPerFrame;
            }
            
            break;
        }
        case kAudioFileStreamProperty_FileFormat:
        {
            char fileFormat[4];
            UInt32 fileFormatSize = sizeof(fileFormat);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat);
            
            break;
        }
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription newBasicDescription;
            if (!self->parsedHeader)
            {
                UInt32 size = sizeof(newBasicDescription);
                
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);
                
                pthread_mutex_lock(&_entryMutex);
                
                if (self->audioStreamBasicDescription.mFormatID == 0)
                {
                    self->audioStreamBasicDescription = newBasicDescription;
                }
                
                self->sampleRate = self->audioStreamBasicDescription.mSampleRate;
                self->packetDuration = self->audioStreamBasicDescription.mFramesPerPacket / self->sampleRate;
                
                UInt32 streamPacketBufferSize = 0;
                UInt32 sizeOfStreamPacketBufferSize = sizeof(packetBufferSize);
                
                error = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfStreamPacketBufferSize, &streamPacketBufferSize);
                
                if (error || streamPacketBufferSize == 0)
                {
                    error = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfStreamPacketBufferSize, &streamPacketBufferSize);
                    
                    if (error || streamPacketBufferSize == 0)
                    {
                        self->packetBufferSize = STK_DEFAULT_PACKET_BUFFER_SIZE;
                    }
                    else
                    {
                        self->packetBufferSize = streamPacketBufferSize;
                    }
                }
                else
                {
                    self->packetBufferSize = streamPacketBufferSize;
                }
                
                [self createAudioConverter:&audioStreamBasicDescription];
                
                pthread_mutex_unlock(&_entryMutex);
            }
            
            break;
        }
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt32 byteCountSize = sizeof(self->audioDataByteCount);
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &(self->audioDataByteCount));
            
            break;
        }
        case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            if (kAudioFormatLinearPCM != _audioConverterAudioStreamBasicDescription.mFormatID)
            {
                _discontinuousData = YES;
            }
            
            break;
        }
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (err)
            {
                break;
            }
            
            AudioFormatListItem* formatList = malloc(formatListSize);
            
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
                {
                    self->audioStreamBasicDescription = pasbd;
                    break;
                }
            }
            
            free(formatList);
            
            break;
        }
    }
}


void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
    STKMixableQueueEntry* entry = (__bridge STKMixableQueueEntry*)clientData;
    [entry handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}


-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptionsIn
{
    if (!self->parsedHeader)
    {
        return;
    }
    
//    if (disposeWasRequested)
//    {
//        return;
//    }
    
    if (_audioConverter == nil)
    {
        return;
    }
    
//    if ((seekToTimeWasRequested && [currentlyPlayingEntry calculatedBitRate] > 0.0))
//    {
//        [self wakeupPlaybackThread];
//        return;
//    }
    
    _discontinuousData = NO;
    
    OSStatus status = 0;
    
    AudioConvertInfo convertInfo;
    
    convertInfo.done = NO;
    convertInfo.numberOfPackets = numberPackets;
    convertInfo.packetDescriptions = packetDescriptionsIn;
    convertInfo.audioBuffer.mData = (void *)inputData;
    convertInfo.audioBuffer.mDataByteSize = numberBytes;
    convertInfo.audioBuffer.mNumberChannels = _audioConverterAudioStreamBasicDescription.mChannelsPerFrame;
    
    if (packetDescriptionsIn && self->processedPacketsCount < STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION)
    {
        int count = MIN(numberPackets, STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION - self->processedPacketsCount);
        for (int i = 0; i < count; i++)
        {
            SInt64 packetSize;
            
            packetSize = packetDescriptionsIn[i].mDataByteSize;
            
            OSAtomicAdd32((int32_t)packetSize, &self->processedPacketsSizeTotal);
            OSAtomicIncrement32(&self->processedPacketsCount);
        }
    }
    
    while (true)
    {
        OSSpinLockLock(&self->spinLock);
        UInt32 used = _pcmBufferUsedFrameCount;
        UInt32 start = _pcmBufferFrameStartIndex;
        UInt32 end = (_pcmBufferFrameStartIndex + _pcmBufferUsedFrameCount) % _pcmBufferTotalFrameCount;
        UInt32 framesLeftInsideBuffer = _pcmBufferTotalFrameCount - used;
        OSSpinLockUnlock(&self->spinLock);
        
        if (framesLeftInsideBuffer == 0)
        {
            pthread_mutex_lock(&_entryMutex);
            
            while (true)
            {
                OSSpinLockLock(&self->spinLock);
                used = _pcmBufferUsedFrameCount;
                start = _pcmBufferFrameStartIndex;
                end = (_pcmBufferFrameStartIndex + _pcmBufferUsedFrameCount) % _pcmBufferTotalFrameCount;
                framesLeftInsideBuffer = _pcmBufferTotalFrameCount - used;
                OSSpinLockUnlock(&self->spinLock);
                
                if (framesLeftInsideBuffer > 0)
                {
                    break;
                }
                
                if (NO == _continueRunLoop) {
                    pthread_mutex_unlock(&_entryMutex);
                    return;
                }
                
                _waiting = YES;
                
                pthread_cond_wait(&_playerThreadReadyCondition, &_entryMutex);
                
                _waiting = NO;
            }
            
            pthread_mutex_unlock(&_entryMutex);
        }
        
        AudioBuffer* localPcmAudioBuffer;
        AudioBufferList localPcmBufferList;
        
        localPcmBufferList.mNumberBuffers = 1;
        localPcmAudioBuffer = &localPcmBufferList.mBuffers[0];
        
        if (end >= start)
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = _pcmBufferTotalFrameCount - end;
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData + (end * _pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
            
            framesToDecode = start;
            
            if (framesToDecode == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                continue;
            }
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData;
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded += framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                continue;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
        }
        else
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = start - end;
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData + (end * _pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;
            
            if (status == 100)
            {
                // TODO: This is used about a million times. Move to function
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);

                continue;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
        }
    }
}


#pragma mark Run Loop/Threading management


- (void)startPlaybackThread
{
    pthread_mutexattr_t attr;
    
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    
    pthread_mutex_init(&_entryMutex, &attr);
    pthread_cond_init(&_playerThreadReadyCondition, NULL);
    
    _playbackThread = [[NSThread alloc] initWithTarget:self selector:@selector(internalThread) object:nil];
    _playbackThread.name = [NSString stringWithFormat:@"Queue item %@", self.queueItemId];
    
    [_playbackThread start];
}

- (void)internalThread
{
    while (nil == _playbackThreadRunLoop) {
        pthread_mutex_lock(&_entryMutex);
        _playbackThreadRunLoop = [NSRunLoop currentRunLoop];
        pthread_mutex_unlock(&_entryMutex);
    }
    
    NSThread.currentThread.threadPriority = 1;
    [_playbackThreadRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
    
    while (true)
    {        
        @autoreleasepool
        {
            if (![self processRunLoop])
            {
                break;
            }
        }
        
        NSDate* date = [[NSDate alloc] initWithTimeIntervalSinceNow:10];
        [_playbackThreadRunLoop runMode:NSDefaultRunLoopMode beforeDate:date];
    }
    
    _playbackThreadRunLoop = nil;
    [self freeResources];
}


/*
 @brief Management of threaded queue entries and preparation for playback
 
 @return YES if processing should continue, otherwise NO.
 */
-(BOOL) processRunLoop
{
    return _continueRunLoop;
}

-(BOOL) invokeOnPlaybackThread:(void(^)())block
{
    NSRunLoop* runLoop = _playbackThreadRunLoop;
    
    if (runLoop)
    {
        CFRunLoopPerformBlock([runLoop getCFRunLoop], NSRunLoopCommonModes, block);
        CFRunLoopWakeUp([runLoop getCFRunLoop]);
        
        return YES;
    }
    
    return NO;
}

-(void) continueBuffering
{
    pthread_mutex_lock(&_entryMutex);
    
    if (_waiting)
    {
        pthread_cond_signal(&_playerThreadReadyCondition);
    }
    
    pthread_mutex_unlock(&_entryMutex);
}

-(void) wakeupPlaybackThread
{
    [self invokeOnPlaybackThread:^ {
        [self continueBuffering];
    }];
}

-(void) stopThread
{
    _continueRunLoop = NO;
    pthread_cond_signal(&_playerThreadReadyCondition);
}


#pragma mark Tidy

- (void)tidyUp
{
    self.dataSource.delegate = nil;
    
    [self.dataSource unregisterForEvents];
    [self.dataSource close];
    
    [self stopThread];
}

- (void)freeResources {
    
    if (_fileStream)
    {
        AudioFileStreamClose(_fileStream);
        _fileStream = nil;
    }
    
    if (_audioConverter)
    {
        AudioConverterDispose(_audioConverter);
        _audioConverter = nil;
    }
    
    free(_readBuffer);
    free(_pcmAudioBufferList.mBuffers[0].mData);
    
    _pcmAudioBufferList.mBuffers[0].mData = NULL;
    _pcmAudioBuffer = NULL;
    
    pthread_mutex_destroy(&_entryMutex);
    pthread_cond_destroy(&_playerThreadReadyCondition);
}

@end
