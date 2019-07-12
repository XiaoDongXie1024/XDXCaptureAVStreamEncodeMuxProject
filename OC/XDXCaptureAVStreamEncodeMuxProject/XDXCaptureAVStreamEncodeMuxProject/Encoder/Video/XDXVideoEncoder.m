//
//  XDXVideoEncoder.m
//  XDXVideoEncoder
//
//  Created by 小东邪 on 2019/5/13.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXVideoEncoder.h"
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#include "log4cplus.h"

uint32_t g_av_base_time = 0;

static const size_t  kStartCodeLength = 4;
static const uint8_t kStartCode[]     = {0x00, 0x00, 0x00, 0x01};

@interface XDXVideoEncoder ()

// encoder property
@property (assign, nonatomic) BOOL isSupportEncoder;
@property (assign, nonatomic) BOOL isSupportRealTimeEncode;
@property (assign, nonatomic) BOOL needForceInsertKeyFrame;
@property (assign, nonatomic) int  width;
@property (assign, nonatomic) int  height;
@property (assign, nonatomic) int  fps;
@property (assign, nonatomic) int  bitrate;
@property (assign, nonatomic) int  errorCount;

@property (assign, nonatomic) BOOL                   needResetKeyParamSetBuffer;
@property (strong, nonatomic) NSLock                 *lock;
@property (strong, nonatomic) NSMutableArray         *averageBitratesArray;

@end

@implementation XDXVideoEncoder
{
    VTCompressionSessionRef     mSession;
}

static XDXVideoEncoder *m_encoder = NULL;
void   printfBuffer(uint8_t* buf, int size, char* name);
void   writeFile(uint8_t *buf, int size, FILE *videoFile, int frameCount);

#pragma mark - Callback
static void EncodeCallBack(void *outputCallbackRefCon,void *souceFrameRefCon,OSStatus status,VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    XDXVideoEncoder *encoder = (__bridge XDXVideoEncoder*)outputCallbackRefCon;
    
    if(status != noErr) {
        NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        NSLog(@"H264: vtCallBack failed with %@", error);
        log4cplus_error("TVUEncoder", "encode frame failured! %s" ,error.debugDescription.UTF8String);
        return;
    }
    
    if (!encoder.isSupportEncoder) {
        return;
    }
    
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    
    // Use our define time. (the time is used to sync audio and video)
    int64_t ptsAfter = (int64_t)((CMTimeGetSeconds(pts) - g_av_base_time) * 1000);
    int64_t dtsAfter = (int64_t)((CMTimeGetSeconds(dts) - g_av_base_time) * 1000);
    dtsAfter = ptsAfter;
    
    /*sometimes relative dts is zero, provide a workground to restore dts*/
    static int64_t last_dts = 0;
    if(dtsAfter == 0){
        dtsAfter = last_dts +33;
    }else if (dtsAfter == last_dts){
        dtsAfter = dtsAfter + 1;
    }
    
    BOOL isKeyFrame = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if(attachments != NULL) {
        CFDictionaryRef attachment =(CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef dependsOnOthers = (CFBooleanRef)CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers);
        isKeyFrame = (dependsOnOthers == kCFBooleanFalse);
    }
    
    if(isKeyFrame) {
        static uint8_t *keyParameterSetBuffer    = NULL;
        static size_t  keyParameterSetBufferSize = 0;
        
        // Note: the NALU header will not change if video resolution not change.
        if (keyParameterSetBufferSize == 0 || YES == encoder.needResetKeyParamSetBuffer) {
            const uint8_t  *vps, *sps, *pps;
            size_t         vpsSize, spsSize, ppsSize;
            int            NALUnitHeaderLengthOut;
            size_t         parmCount;
            
            if (keyParameterSetBuffer != NULL) {
                free(keyParameterSetBuffer);
            }
            
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (encoder.encoderType == XDXH264Encoder) {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &parmCount, &NALUnitHeaderLengthOut);
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &ppsSize, &parmCount, &NALUnitHeaderLengthOut);
                
                keyParameterSetBufferSize = spsSize+4+ppsSize+4;
                keyParameterSetBuffer = (uint8_t*)malloc(keyParameterSetBufferSize);
                memcpy(keyParameterSetBuffer, "\x00\x00\x00\x01", 4);
                memcpy(&keyParameterSetBuffer[4], sps, spsSize);
                memcpy(&keyParameterSetBuffer[4+spsSize], "\x00\x00\x00\x01", 4);
                memcpy(&keyParameterSetBuffer[4+spsSize+4], pps, ppsSize);
                
                log4cplus_info("Video Encoder:", "H264 find IDR frame， spsSize : %zu, ppsSize : %zu",spsSize, ppsSize);
            }else if (encoder.encoderType == XDXH265Encoder) {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &vps, &vpsSize, &parmCount, &NALUnitHeaderLengthOut);
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 1, &sps, &spsSize, &parmCount, &NALUnitHeaderLengthOut);
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 2, &pps, &ppsSize, &parmCount, &NALUnitHeaderLengthOut);
                
                keyParameterSetBufferSize = vpsSize+4+spsSize+4+ppsSize+4;
                keyParameterSetBuffer = (uint8_t*)malloc(keyParameterSetBufferSize);
                memcpy(keyParameterSetBuffer, "\x00\x00\x00\x01", 4);
                memcpy(&keyParameterSetBuffer[4], vps, vpsSize);
                memcpy(&keyParameterSetBuffer[4+vpsSize], "\x00\x00\x00\x01", 4);
                memcpy(&keyParameterSetBuffer[4+vpsSize+4], sps, spsSize);
                memcpy(&keyParameterSetBuffer[4+vpsSize+4+spsSize], "\x00\x00\x00\x01", 4);
                memcpy(&keyParameterSetBuffer[4+vpsSize+4+spsSize+4], pps, ppsSize);
                log4cplus_info("Video Encoder:", "H265 find IDR frame, vpsSize : %zu, spsSize : %zu, ppsSize : %zu",vpsSize,spsSize, ppsSize);
            }
            
            encoder.needResetKeyParamSetBuffer = NO;
        }
        
        struct XDXVideEncoderData encoderData = {
            .isKeyFrame  = NO,
            .isExtraData = YES,
            .data        = keyParameterSetBuffer,
            .size        = keyParameterSetBufferSize,
            .timestamp   = dtsAfter,
        };
        
        if ([encoder.delegate respondsToSelector:@selector(receiveVideoEncoderData:)]) {
            [encoder.delegate receiveVideoEncoderData:&encoderData];
        }
        
        log4cplus_info("Video Encoder:", "Load a I frame.");
    }
    
    size_t   blockBufferLength;
    uint8_t  *bufferDataPointer = NULL;
    CMBlockBufferGetDataPointer(block, 0, NULL, &blockBufferLength, (char **)&bufferDataPointer);
    
    size_t bufferOffset = 0;
    while (bufferOffset < blockBufferLength - kStartCodeLength)
    {
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, bufferDataPointer+bufferOffset, kStartCodeLength);
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
        memcpy(bufferDataPointer+bufferOffset, kStartCode, kStartCodeLength);
        bufferOffset += kStartCodeLength + NALUnitLength;
    }
    
    struct XDXVideEncoderData encoderData = {
        .isKeyFrame  = isKeyFrame,
        .isExtraData = NO,
        .data        = bufferDataPointer,
        .size        = blockBufferLength,
        .timestamp   = dtsAfter,
    };
    
    if ([encoder.delegate respondsToSelector:@selector(receiveVideoEncoderData:)]) {
        [encoder.delegate receiveVideoEncoderData:&encoderData];
    }
    
//    log4cplus_debug("Video Encoder:","H265 encoded video:%lld, size:%lu, interval:%lld", dtsAfter,blockBufferLength, dtsAfter - last_dts);
    
    last_dts = dtsAfter;
}

#pragma mark - Public
-(instancetype)initWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate isSupportRealTimeEncode:(BOOL)isSupportRealTimeEncode encoderType:(XDXVideoEncoderType)encoderType {
    if (self = [super init]) {
        mSession              = NULL;
        _width                = width;
        _height               = height;
        _fps                  = fps;
        _bitrate              = bitrate << 10;  //convert to bps
        _errorCount           = 0;
        _isSupportEncoder     = NO;
        _encoderType          = encoderType;
        _lock                 = [[NSLock alloc] init];
        _isSupportRealTimeEncode = isSupportRealTimeEncode;
        _needResetKeyParamSetBuffer = YES;
        if (encoderType == XDXH265Encoder) {
            if (@available(iOS 11.0, *)) {
                if ([[AVAssetExportSession allExportPresets] containsObject:AVAssetExportPresetHEVCHighestQuality]) {
                    _isSupportEncoder = YES;
                }
            }
        }else if (encoderType == XDXH264Encoder){
            _isSupportEncoder = YES;
        }
        
        log4cplus_info("Video Encoder:","Init encoder width:%d, height:%d, fps:%d, bitrate:%d, is support encoder:%d, encoder type:H%lu", width, height, fps, bitrate, isSupportRealTimeEncode, (unsigned long)encoderType);
    }
    
    return self;
}

- (void)configureEncoderWithWidth:(int)width height:(int)height {
    log4cplus_info("Video Encoder:", "configure encoder with and height for init,with = %d,height = %d",width, height);
    
    if(width == 0 || height == 0) {
        log4cplus_error("Video Encoder:", "encoder param can't is null. width:%d, height:%d",width, height);
        return;
    }
    
    self.width   = width;
    self.height  = height;
    
    mSession = [self configureEncoderWithEncoderType:self.encoderType
                                            callback:EncodeCallBack
                                               width:self.width
                                              height:self.height
                                                 fps:self.fps
                                             bitrate:self.bitrate
                             isSupportRealtimeEncode:self.isSupportRealTimeEncode
                                      iFrameDuration:10
                                                lock:self.lock];
}

- (void)startEncodeDataWithBuffer:(CMSampleBufferRef)buffer isNeedFreeBuffer:(BOOL)isNeedFreeBuffer {
    [self startEncodeWithBuffer:buffer
                        session:mSession
               isNeedFreeBuffer:isNeedFreeBuffer
                         isDrop:NO
        needForceInsertKeyFrame:self.needForceInsertKeyFrame
                           lock:self.lock];
    
    if (self.needForceInsertKeyFrame) {
        self.needForceInsertKeyFrame = NO;
    }
}

- (void)freeVideoEncoder {
    [self tearDownSessionWithSession:mSession
                                lock:self.lock];
}

- (void)forceInsertKeyFrame {
    self.needForceInsertKeyFrame = YES;
}

#pragma mark - Private
#pragma mark Init
- (VTCompressionSessionRef)configureEncoderWithEncoderType:(XDXVideoEncoderType)encoderType callback:(VTCompressionOutputCallback)callback width:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate isSupportRealtimeEncode:(BOOL)isSupportRealtimeEncode iFrameDuration:(int)iFrameDuration lock:(NSLock *)lock {
    log4cplus_info("Video Encoder:","configure encoder width:%d, height:%d, fps:%d, bitrate:%d, is support realtime encode:%d, I frame duration:%d", width, height, fps, bitrate, isSupportRealtimeEncode, iFrameDuration);
    
    [lock lock];
    // Create compression session
    VTCompressionSessionRef session = [self createCompressionSessionWithEncoderType:encoderType
                                                                              width:width
                                                                             height:height
                                                                           callback:callback];
    
    // Set compresssion property
    [self setCompressionSessionPropertyWithSession:session
                                               fps:fps
                                           bitrate:bitrate
                           isSupportRealtimeEncode:isSupportRealtimeEncode
                                    iFrameDuration:iFrameDuration
                                       EncoderType:encoderType];
    
    // Prepare to encode
    OSStatus status = VTCompressionSessionPrepareToEncodeFrames(session);
    [lock unlock];
    if(status != noErr) {
        if (session) {
            [self tearDownSessionWithSession:session lock:lock];
        }
        log4cplus_error("Video Encoder:", "create encoder failed, status: %d",(int)status);
        return NULL;
    }else {
        log4cplus_info("Video Encoder:","create encoder success");
        return session;
    }
}

- (VTCompressionSessionRef)createCompressionSessionWithEncoderType:(XDXVideoEncoderType)encoderType width:(int)width height:(int)height callback:(VTCompressionOutputCallback)callback {
    CMVideoCodecType codecType;
    if (encoderType == XDXH264Encoder) {
        codecType = kCMVideoCodecType_H264;
    }else if (encoderType == XDXH265Encoder) {
        codecType = kCMVideoCodecType_HEVC;
    }else {
        return nil;
    }
    
    VTCompressionSessionRef session;
    OSStatus status = VTCompressionSessionCreate(NULL,
                                                 width,
                                                 height,
                                                 codecType,
                                                 NULL,
                                                 NULL,
                                                 NULL,
                                                 callback,
                                                 (__bridge void *)self,
                                                 &session);
    
    if (status != noErr) {
        log4cplus_error("Video Encoder:", "%s: Create session failed:%d",__func__,(int)status);
        return nil;
    }else {
        return session;
    }
}

- (void)setCompressionSessionPropertyWithSession:(VTCompressionSessionRef)session fps:(int)fps bitrate:(int)bitrate isSupportRealtimeEncode:(BOOL)isSupportRealtimeEncode iFrameDuration:(int)iFrameDuration EncoderType:(XDXVideoEncoderType)encoderType {
    
    int maxCount = 3;
    if (!isSupportRealtimeEncode) {
        if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_MaxFrameDelayCount]) {
            CFNumberRef ref   = CFNumberCreate(NULL, kCFNumberSInt32Type, &maxCount);
            [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_MaxFrameDelayCount value:ref];
            CFRelease(ref);
        }
    }
    
    if(fps) {
        if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_ExpectedFrameRate]) {
            int         value = fps;
            CFNumberRef ref   = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
            [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_ExpectedFrameRate value:ref];
            CFRelease(ref);
        }
    }else {
        log4cplus_error("Video Encoder:", "Current fps is 0");
        return;
    }
    
    if(bitrate) {
        if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_AverageBitRate]) {
            int value = bitrate;
            CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
            [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_AverageBitRate value:ref];
            CFRelease(ref);
        }
    }else {
        log4cplus_error("Video Encoder:", "Current bitrate is 0");
        return;
    }
    
    
    if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_RealTime]) {
        log4cplus_info("Video Encoder:", "use realTimeEncoder");
        [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_RealTime value:isSupportRealtimeEncode ? kCFBooleanTrue : kCFBooleanFalse];
    }
    
    // Ban B frame.
    if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_AllowFrameReordering]) {
        [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_AllowFrameReordering value:kCFBooleanFalse];
    }
    
    if (encoderType == XDXH264Encoder) {
        if (isSupportRealtimeEncode) {
            if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel]) {
                [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel value:kVTProfileLevel_H264_Main_AutoLevel];
            }
        }else {
            if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel]) {
                [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel value:kVTProfileLevel_H264_Baseline_AutoLevel];
            }
            
            if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_H264EntropyMode]) {
                [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_H264EntropyMode value:kVTH264EntropyMode_CAVLC];
            }
        }
    }else if (encoderType == XDXH265Encoder) {
        if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel]) {
            [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_ProfileLevel value:kVTProfileLevel_HEVC_Main_AutoLevel];
        }
    }
    
    
    if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration]) {
        int         value   = iFrameDuration;
        CFNumberRef ref     = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
        [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration value:ref];
        CFRelease(ref);
    }
    
    log4cplus_info("Video Encoder:", "The compression session max frame delay count = %d, expected frame rate = %d, average bitrate = %d, is support realtime encode = %d, I frame duration = %d",maxCount, fps, bitrate, isSupportRealtimeEncode,iFrameDuration);
}

- (OSStatus)setSessionPropertyWithSession:(VTCompressionSessionRef)session key:(CFStringRef)key value:(CFTypeRef)value {
    if (value == nil || value == NULL || value == 0x0) {
        return noErr;
    }
    
    OSStatus status = VTSessionSetProperty(session, key, value);
    if (status != noErr)  {
        log4cplus_error("Video Encoder:", "Set session of %s Failed, status = %d",CFStringGetCStringPtr(key, kCFStringEncodingUTF8),status);
    }
    return status;
}

- (BOOL)isSupportPropertyWithSession:(VTCompressionSessionRef)session key:(CFStringRef)key {
    OSStatus status;
    static CFDictionaryRef supportedPropertyDictionary;
    if (!supportedPropertyDictionary) {
        status = VTSessionCopySupportedPropertyDictionary(session, &supportedPropertyDictionary);
        if (status != noErr) {
            return NO;
        }
    }
    
    BOOL isSupport = [NSNumber numberWithBool:CFDictionaryContainsKey(supportedPropertyDictionary, key)].intValue;
    return isSupport;
}

#pragma mark encode method
-(void)startEncodeWithBuffer:(CMSampleBufferRef)sampleBuffer session:(VTCompressionSessionRef)session isNeedFreeBuffer:(BOOL)isNeedFreeBuffer isDrop:(BOOL)isDrop  needForceInsertKeyFrame:(BOOL)needForceInsertKeyFrame lock:(NSLock *)lock {
    [lock lock];
    
    if(session == NULL) {
        log4cplus_error("Video Encoder:", "%s,session is empty",__func__);
        [self handleEncodeFailedWithIsNeedFreeBuffer:isNeedFreeBuffer sampleBuffer:sampleBuffer];
        return;
    }
    
    //the first frame must be iframe then create the reference timeStamp;
    static BOOL isFirstFrame = YES;
    if(isFirstFrame && g_av_base_time == 0) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        g_av_base_time = CMTimeGetSeconds(pts);// system absolutly time(s)
        //        g_av_base_time = g_tvustartcaptureTime - (ntp_time_offset/1000);
        isFirstFrame = NO;
        log4cplus_error("Video Encoder:","start capture time = %u",g_av_base_time);
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    // Switch different source data will show mosaic because timestamp not sync.
    static int64_t lastPts = 0;
    int64_t currentPts = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000);
    if (currentPts - lastPts < 0) {
        log4cplus_error("Video Encoder:","Switch different source data the timestamp < last timestamp, currentPts = %lld, lastPts = %lld, duration = %lld",currentPts, lastPts, currentPts - lastPts);
        [self handleEncodeFailedWithIsNeedFreeBuffer:isNeedFreeBuffer sampleBuffer:sampleBuffer];
        return;
    }
    lastPts = currentPts;
    
    OSStatus status = noErr;
    NSDictionary *properties = @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame:@(needForceInsertKeyFrame)};
    status = VTCompressionSessionEncodeFrame(session,
                                             imageBuffer,
                                             presentationTimeStamp,
                                             kCMTimeInvalid,
                                             (__bridge CFDictionaryRef)properties,
                                             NULL,
                                             NULL);
    
    if(status != noErr) {
        log4cplus_error("Video Encoder:", "encode frame failed");
        [self handleEncodeFailedWithIsNeedFreeBuffer:isNeedFreeBuffer sampleBuffer:sampleBuffer];
    }
    
    [lock unlock];
    if (isNeedFreeBuffer) {
        if (sampleBuffer != NULL) {
            CFRelease(sampleBuffer);
            log4cplus_debug("Video Encoder:", "release the sample buffer");
        }
    }
}

- (void)handleEncodeFailedWithIsNeedFreeBuffer:(BOOL)isNeedFreeBuffer sampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // if sample buffer are from system needn't to release, if sample buffer are from we create need to release.
    [self.lock unlock];
    if (isNeedFreeBuffer) {
        if (sampleBuffer != NULL) {
            CFRelease(sampleBuffer);
            log4cplus_debug("Video Encoder:", "release the sample buffer");
        }
    }
}

#pragma mark - Other
-(BOOL)needAdjustBitrateWithBitrate:(int)bitrate averageBitratesArray:(NSMutableArray *)averageBitratesArray {
    CMClockRef   hostClockRef = CMClockGetHostTimeClock();
    CMTime       hostTime     = CMClockGetTime(hostClockRef);
    static float lastTime     = 0;
    float now = CMTimeGetSeconds(hostTime);
    if(now - lastTime < 0.5) {
        [averageBitratesArray addObject:[NSNumber numberWithInt:bitrate]];
        return NO;
    }else {
        NSUInteger count = [averageBitratesArray count];
        if(count == 0) return YES;
        
        int sum = 0;
        for (NSNumber *num in averageBitratesArray) {
            sum += num.intValue;
        }
        
        int average  = sum/count;
        self.bitrate = average;
        
        [averageBitratesArray removeAllObjects];
        lastTime = now;
        return YES;
    }
}

-(void)doSetBitrateWithSession:(VTCompressionSessionRef)session isSupportRealtimeEncode:(BOOL)isSupportRealtimeEncode bitrate:(int)bitrate averageBitratesArray:(NSMutableArray *)averageBitratesArray {
    if(!isSupportRealtimeEncode) {
        return;
    }
    
    if(![self needAdjustBitrateWithBitrate:bitrate averageBitratesArray:averageBitratesArray]) {
        return;
    }
    
    int tmp         = bitrate;
    int bytesTmp    = tmp >> 3;
    int durationTmp = 1;
    
    CFNumberRef bitrateRef   = CFNumberCreate(NULL, kCFNumberSInt32Type, &tmp);
    CFNumberRef bytes        = CFNumberCreate(NULL, kCFNumberSInt32Type, &bytesTmp);
    CFNumberRef duration     = CFNumberCreate(NULL, kCFNumberSInt32Type, &durationTmp);
    
    
    if (session) {
        if ([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_AverageBitRate]) {
            [self setSessionPropertyWithSession:session key:kVTCompressionPropertyKey_AverageBitRate value:bitrateRef];
        }else {
            log4cplus_error("Video Encoder:", "set average bitRate error");
        }
        
        log4cplus_debug("Video Encoder:","set bitrate bytes = %d, _bitrate = %d",bytesTmp, bitrate);
        
        CFMutableArrayRef limit = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
        CFArrayAppendValue(limit, bytes);
        CFArrayAppendValue(limit, duration);
        if([self isSupportPropertyWithSession:session key:kVTCompressionPropertyKey_DataRateLimits]) {
            OSStatus ret = VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, limit);
            if(ret != noErr){
                NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
                log4cplus_error("Video Encoder:", "set DataRateLimits failed with %s",error.description.UTF8String);
            }
        }else {
            log4cplus_error("Video Encoder:", "set data rate limits error");
        }
        CFRelease(limit);
    }
    
    CFRelease(bytes);
    CFRelease(duration);
}

#pragma mark - Dealloc
-(void)tearDownSessionWithSession:(VTCompressionSessionRef)session lock:(NSLock *)lock {
    log4cplus_error("Video Encoder:","tear down session");
    [lock lock];
    
    if (session == NULL) {
        log4cplus_error("Video Encoder:", "%s current compression is NULL",__func__);
        [lock unlock];
        return;
    }else {
        VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
        session = NULL;
    }
    
    [lock unlock];
}

- (void)dealloc {
    [self tearDownSessionWithSession:mSession lock:self.lock];
}

#pragma mark  Print Buffer Content And Write File
void printfBuffer(uint8_t* buf, int size, char* name) {
    int i = 0;
    printf("%s:", name);
    for(i = 0; i < size; i++){
        printf("%02x,", buf[i]);
    }
    printf("\n");
}

@end
