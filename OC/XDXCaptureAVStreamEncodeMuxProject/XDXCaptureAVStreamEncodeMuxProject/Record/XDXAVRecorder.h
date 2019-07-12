//
//  XDXAVRecorder.h
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/9.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XDXAVRecorder : NSObject

/**
 * Start / Stop record.
 * Note: Write header at first.
 */
- (void)startRecordWithIsHead:(BOOL)isHead data:(char *)data size:(int)size;
- (void)stopRecord;

@end

NS_ASSUME_NONNULL_END
