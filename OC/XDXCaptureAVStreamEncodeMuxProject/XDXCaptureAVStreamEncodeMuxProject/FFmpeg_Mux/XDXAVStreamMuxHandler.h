//
//  XDXAVStreamMuxHandler.h
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/7.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XDXSingleton.h"

#ifdef __cplusplus
extern "C"
{
#endif
    
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libavutil/error.h"
#include "libswscale/swscale.h"
#include <libavutil/dict.h>
#include <time.h>
#include <stdio.h>
#ifdef __cplusplus
}
#endif

#include <stdio.h>
#include <pthread.h>
#include <list>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    XDXMuxVideoFormatNone,
    XDXMuxVideoFormatH264 = 264,
    XDXMuxVideoFormatH265 = 265,
} XDXMuxVideoFormat;

@protocol XDXAVStreamMuxDelegate <NSObject>

@optional
- (void)receiveAVStreamWithIsHead:(BOOL)isHead data:(uint8_t *)data size:(int)size;

@end

@interface XDXAVStreamMuxHandler : NSObject

@property (weak  , nonatomic) id<XDXAVStreamMuxDelegate> delegate;

+ (instancetype)sharedInstance;


/**
 * Must call it once after the instance init.
 */
- (void)prepareForMux;


/**
 * Add audio and video data to mux.
 */
- (void)addVideoData:(uint8_t *)data
                size:(int)size
           timestamp:(int64_t)timestamp
          isKeyFrame:(BOOL)isKeyFrame
         isExtraData:(BOOL)isExtraData
         videoFormat:(XDXMuxVideoFormat)videoFormat;

- (void)addAudioData:(uint8_t *)data
                size:(int)size
          channelNum:(int)channelNum
          sampleRate:(int)sampleRate
           timestamp:(int64_t)timestamp;


/**
 * Get av stream head data and size.
 */
- (void *)getAVStreamHeadWithSize:(int *)size;

@end

NS_ASSUME_NONNULL_END
