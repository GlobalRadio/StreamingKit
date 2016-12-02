//
//  STKAdaptiveURLHTTPDataSource.m
//  StreamingKit
//
//  Created by James Gordon on 09/09/2015.
//  Copyright (c) 2015 Thong Nguyen. All rights reserved.
//

#import "STKHtTPDataSourceProtected.h"
#import "STKAdaptiveURLHTTPDataSource.h"

@implementation STKAdaptiveURLHTTPDataSource


/*
 We're overriding the header parsing, as we want to offer the ability immediately skip to an offset within the
 finite file we're streaming. On return from super, if we detect that seek is supported AND we need to skip,
 we will return NO, which will invoke the skip.
 */
- (BOOL)parseHttpHeader {
    
    BOOL result = [super parseHttpHeader];
    
    if (self.httpStatusCode == 200 && requestedStartOffset) {
        result = NO;
    }
    
    return result;
}


/*
 Here is where we destroy the very fabric of space and time by throwing away the expired URL and using a shiny
 new one.
 */
- (void)switchToURL:(NSURL *)inURL {
    
    [self close];
    
    STKURLProvider urlProvider = ^NSURL* { return inURL; };
    STKAsyncURLProvider asyncProvider = ^(STKHTTPDataSource* dataSource, BOOL forSeek, STKURLBlock block)
    {
        block(urlProvider());
    };
    
    self->asyncUrlProvider = [asyncProvider copy];
}

@end
