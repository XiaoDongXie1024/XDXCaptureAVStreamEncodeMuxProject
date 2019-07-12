//
//  XDXAVPacketList.h
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/8.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C"
{
#endif
    
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avstring.h"
#include "libswscale/swscale.h"
    //#include "libavcodec/audioconvert.h"
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    XDXMuxVideoType,
    XDXMuxAudioType,
} XDXMuxMediaType;

typedef struct {
    AVPacket        *data;
    u_int64_t       timeStamp;
    XDXMuxMediaType datatype;
    BOOL            extraDataHasChanged;
}XDXMuxMediaList;


@interface XDXAVPacketList : NSObject

- (BOOL)pushData:(XDXMuxMediaList)data;
- (void)popData:(XDXMuxMediaList *)mediaList;


- (void)reset;
- (int )count;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
