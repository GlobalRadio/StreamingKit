//
//  STKConstants.h
//  StreamingKit
//
//  Created by James Gordon on 10/12/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#ifndef StreamingKit_STKConstants_h
#define StreamingKit_STKConstants_h

#import <AudioToolbox/AudioToolbox.h>

#ifndef DBL_MAX
#define DBL_MAX 1.7976931348623157e+308
#endif

#pragma mark Defines

#define STK_DBMIN (-60)
#define STK_DBOFFSET (-74.0)
#define STK_LOWPASSFILTERTIMESLICE (0.0005)

#define STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS (10)
#define STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING (1)
#define STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING_AFTER_BUFFER_UNDERRUN (7.5)
#define STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION (4096)
#define STK_DEFAULT_READ_BUFFER_SIZE (64 * 1024)
#define STK_DEFAULT_PACKET_BUFFER_SIZE (2048)
#define STK_DEFAULT_GRACE_PERIOD_AFTER_SEEK_SECONDS (0.5)

typedef struct
{
    BOOL done;
    UInt32 numberOfPackets;
    AudioBuffer audioBuffer;
    AudioStreamPacketDescription* packetDescriptions;
}
AudioConvertInfo;

#endif
