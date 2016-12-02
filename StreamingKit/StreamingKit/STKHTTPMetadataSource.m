/******************************************************************************
 STKHTTPMetadataSource.m
 StreamingKit
 
 Created by James Gordon on 21/08/2014.
 https://github.com/tumtumtum/audjustable
 
 Copyright (c) 2014 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by Thong Nguyen (tumtumtum@gmail.com)
 4. Neither the name of Thong Nguyen nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THONG NGUYEN BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************/

#import "STKHTTPMetadataSource.h"


const int NO_METADATA = -1;


@interface STKHTTPMetadataSource()

@property (nonatomic, retain) NSMutableData *metadataBytes;
@property (readonly) int metadataStep;
@property (readonly) dispatch_queue_t metadataParseQueue;
@property int bytesUntilMetadata;
@property int metadataSize;

// Used for determining when to trigger events
@property SInt64 totalBytesRead;
@property (readonly) float compressedBytesPerFrame;

@end


@implementation STKHTTPMetadataSource


-(id) initWithURL:(NSURL *)url httpRequestHeaders:(NSDictionary *)httpRequestHeaders
{
    self = [super initWithURL:url httpRequestHeaders:httpRequestHeaders];
    if (nil != self)
    {
        _metadataParseQueue = dispatch_queue_create(METADATA_PARSE_QUEUE, DISPATCH_QUEUE_SERIAL);
        self.metadataBytes = [[NSMutableData alloc] init];
    }
    
    return self;
}


-(void) dataAvailable
{
    if (0 == self.metadataStep) {
        // On first response, we want to get data about the stream bitrate and so on for parsing metadata.
        CFTypeRef response = CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
        
        if (response)
        {
            NSDictionary *httpHeaders = (__bridge_transfer NSDictionary*)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)response);
            
            // Get metadata step from icecast response header
            _metadataStep = [httpHeaders[KEY_ICECAST_METADATA_INT] intValue];
            
            if (self.metadataStep > 0) {
                self.bytesUntilMetadata = self.metadataStep;
                
                // Stream header defines bitrate in kbps, but we want bps, so multiply by 1000.
                NSArray *bitrateHeader = [httpHeaders[KEY_ICECAST_BITRATE] componentsSeparatedByString:ICECAST_BITRATE_SEPARATOR];
                float compressedBitrate = [[bitrateHeader objectAtIndex:0] floatValue] * 1000;
                float compressionRatio = compressedBitrate / (self.sampleRate * self.decompressedBitsPerFrame);
                
                // Multiply by 1/8 so we're working in bytes
                _compressedBytesPerFrame = self.decompressedBitsPerFrame * compressionRatio * 0.125;
                
                [self.metadataDelegate didStartReceive];
                
            } else {
                
                // Note that we have no metadata so that we don't keep checking for it.
                _metadataStep = NO_METADATA;
            }
        }
    }
    
    // We still need to do grown up HTTP stuff, so do that now.
    [super dataAvailable];
}


-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    int read = [super readIntoBuffer:buffer withSize:size];
    
    if (self.metadataStep > 0 && read > 0)
    {
        if (self.metadataSize > 0)
        {
            read = [self finishReadingMetadata:buffer bufferLength:read];
        }
        
        if (self.bytesUntilMetadata < read && self.metadataSize == 0)
        {
            read = [self readMetadataFromCurrentBuffer:buffer bufferLength:read];
        }
        
        // We're a buffer length closer to next metadata position
        self.bytesUntilMetadata -= read;
        self.totalBytesRead += read;
    }
    
    return read;
}


#pragma mark Metadata extraction

/*
 @brief Extract any blocks of metadata contained within the passed buffer.
 @discussion    The metadata extraction is cyclic, so if we have multiple blocks of metadata contained within the
                buffer, we'll exctract each one sequentially.
 
 @param buffer containing the input stream data
 @param bufferLength specifies how much data there is to read.
 
 @return length of non-metadata bytes remain in the buffer following extraction
 */
- (int)readMetadataFromCurrentBuffer:(UInt8 *)buffer bufferLength:(int)bufferLength
{
	// We have to use while here, because there might be multiple metadata within single buffer.
	while (self.bytesUntilMetadata < bufferLength && self.metadataSize == 0)
	{
		// Metadata position is within current buffer
		self.metadataSize = buffer[self.bytesUntilMetadata] * METADATA_LENGTH_MULTIPLY_FACTOR;
		int amountOfBytesTillEndOfBuffer = (int)(bufferLength - (self.bytesUntilMetadata + METADATA_INTERVAL_CHAR));
        
		// We can read as much as metadata length or till the end of current buffer
		int amountToRead = MIN(self.metadataSize, amountOfBytesTillEndOfBuffer);
		[self.metadataBytes appendBytes:buffer + self.bytesUntilMetadata + METADATA_INTERVAL_CHAR length:amountToRead];
        
		// Cut of metadata from stream
		int metadataStart = self.bytesUntilMetadata;
		int metadataEnd   = self.bytesUntilMetadata + METADATA_INTERVAL_CHAR + self.metadataSize;
		if (metadataEnd < bufferLength) {
			// metadata cut-off
			memmove(buffer + metadataStart, buffer + metadataEnd, bufferLength - metadataEnd);
		}
        
        self.metadataSize -= amountToRead;
		bufferLength -= (amountToRead + METADATA_INTERVAL_CHAR);
        
		if (self.metadataSize == 0 && [self.metadataBytes length] > 0)
		{
			[self metadataReadSuccessfully:self.metadataBytes];
		}
        
		// calculate position of next metadata in stream
		self.bytesUntilMetadata += self.metadataStep;
	}
    
	return bufferLength;
}


/*
 @brief Attempt to finish read of metadata
 @discussion    If we have a read of metadata that spans multiple bursts of data from the stream, we use this function 
                to append to data already read from previous burst(s) for this block of metadata.
 
 @param buffer  to read from
 @param bufferLength Specifies how much of the buffer there is to read. If this is less than the amount of metadata
                    we have left to read, we'll have to wait for the next stream burst before we can our metadata read.
 
 @return Amount of non-metadata bytes contained within the buffer.
 */
- (int)finishReadingMetadata:(UInt8 *)buffer bufferLength:(int)bufferLength
{
	int amountToRead = MIN(self.metadataSize, bufferLength);
    
	[self.metadataBytes appendBytes:buffer length:amountToRead];
	self.metadataSize -= amountToRead;
    
	if (self.metadataSize == 0)
	{
		[self metadataReadSuccessfully:self.metadataBytes ];
        
		// metadata cut-off
		memmove(buffer, buffer + amountToRead, bufferLength - amountToRead);
        
		return bufferLength - amountToRead;
	}
	else
	{
		// Whole buffer is a metadata, skip it by returning zero-length of audio stream
		return 0;
	}
}


/*
 @brief On completion of reading a metadata block, create an event for future invocation.
 
 @param aMetadataBuffer contains the bytes containing metadata from the stream.
 
 @return void
 */
- (void)metadataReadSuccessfully:(NSMutableData*)aMetadataBuffer
{
    // Very simply want to extract bytes and then alert any insterested listener
    NSData *receivedMetadata = [NSData dataWithBytes:aMetadataBuffer.bytes length:aMetadataBuffer.length];
    aMetadataBuffer.length = 0;
    
    dispatch_async(self.metadataParseQueue, ^{
        [self.metadataDelegate didReceive:receivedMetadata at:(self.totalBytesRead + self.bytesUntilMetadata) / self.compressedBytesPerFrame];
    });
    
}


- (void)dealloc {
    
    // dispatch queues are not auto-released, so make sure we do that here.
    dispatch_release(self.metadataParseQueue);
}


#pragma mark overrides

-(void) reconnect
{
    _metadataStep = 0;
    self.totalBytesRead = 0;
    self.metadataBytes.length = 0;
    
    [super reconnect];
}



@end
