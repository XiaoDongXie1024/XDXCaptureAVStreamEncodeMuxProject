//
//  XDXAudioCaptureManager.h
//  XDXAudioUnitCapture
//
//  Created by 小东邪 on 2019/5/10.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#import "XDXSingleton.h"

NS_ASSUME_NONNULL_BEGIN

struct XDXCaptureAudioData {
    void    *data;
    int     size;
    int64_t pts;
};

typedef struct XDXCaptureAudioData* XDXCaptureAudioDataRef;

@protocol XDXAudioCaptureDelegate <NSObject>

@optional
- (void)receiveAudioDataByDevice:(XDXCaptureAudioDataRef)audioDataRef;

@end


@interface XDXAudioCaptureManager : NSObject
SingletonH

@property (nonatomic, assign, readonly) BOOL isRunning;

@property (nonatomic, weak) id<XDXAudioCaptureDelegate> delegate;

+ (instancetype)getInstance;
- (void)startAudioCapture;
- (void)stopAudioCapture;
- (void)freeAudioUnit;

- (AudioStreamBasicDescription)getAudioDataFormat;

@end

NS_ASSUME_NONNULL_END
