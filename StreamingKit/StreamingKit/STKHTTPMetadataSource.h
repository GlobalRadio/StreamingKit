/******************************************************************************
 STKHTTPMetadataSource.h
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

#define METADATA_LENGTH_MULTIPLY_FACTOR 16
#define METADATA_INTERVAL_CHAR 1
#define KEY_ICECAST_METADATA_INT @"icy-metaint"
#define KEY_ICECAST_BITRATE @"icy-br"
#define ICECAST_BITRATE_SEPARATOR @", "
#define METADATA_PARSE_QUEUE "metadata_parse_queue"

#import "STKHTTPDataSource.h"

@protocol STKHTTPMetadataSoureceDelegate <NSObject>

- (void)didStartReceive;
- (void)didReceive:(NSData *)metadata at:(SInt64)frame;

@end


@interface STKHTTPMetadataSource : STKHTTPDataSource

// Sample frequency in Hz
@property (nonatomic) float sampleRate;

// Use this to determine what frame we're on based on the number of bytes read.
@property (nonatomic) float decompressedBitsPerFrame;

// Who to alert when we receive some metadata.
@property (nonatomic) id<STKHTTPMetadataSoureceDelegate> metadataDelegate;

@end
