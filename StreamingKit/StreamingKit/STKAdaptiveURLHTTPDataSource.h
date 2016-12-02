//
//  STKAdaptiveURLHTTPDataSource.h
//  StreamingKit
//
//  Created by James Gordon on 09/09/2015.
//  Copyright (c) 2015 Thong Nguyen. All rights reserved.
//

#import "STKHTTPDataSource.h"

@interface STKAdaptiveURLHTTPDataSource : STKHTTPDataSource

- (void)switchToURL:(NSURL *)inURL;

@end
