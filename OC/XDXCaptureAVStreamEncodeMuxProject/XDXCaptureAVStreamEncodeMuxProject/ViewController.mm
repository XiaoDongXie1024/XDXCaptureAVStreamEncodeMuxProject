//
//  ViewController.m
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/7.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "XDXCameraModel.h"
#import "XDXCameraHandler.h"
#import "XDXAudioCaptureManager.h"
#import "XDXAduioEncoder.h"
#import "XDXVideoEncoder.h"
#import "XDXAVStreamMuxHandler.h"
#import "XDXAVRecorder.h"

@interface ViewController ()<XDXCameraHandlerDelegate, XDXAudioCaptureDelegate, XDXVideoEncoderDelegate, XDXAVStreamMuxDelegate>

@property (weak, nonatomic) IBOutlet UIButton *startRecordBtn;
@property (weak, nonatomic) IBOutlet UIButton *stopRecordBtn;

// Capture
@property (nonatomic, strong) XDXCameraHandler       *cameraCaptureHandler;
@property (nonatomic, strong) XDXAudioCaptureManager *audioCaptureHandler;

// Encoder
@property (nonatomic, strong) XDXAduioEncoder *audioEncoder;
@property (nonatomic, strong) XDXVideoEncoder *videoEncoder;

// Mux
@property (nonatomic, strong) XDXAVStreamMuxHandler *muxHandler;

// Record mux a/v stream
@property (strong, nonatomic) XDXAVRecorder *recorder;
@property (assign, nonatomic) BOOL          isRecording;

@end

@implementation ViewController

#pragma mark - Lifecycle
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    [self configureCamera];
    [self configureAudioCapture];
    [self configureAudioEncoder];
    [self configurevideoEncoder];
    [self configureAVMuxHandler];
    [self configureAVRecorder];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupUI];
}

#pragma mark - UI
- (void)setupUI {
    [self.view bringSubviewToFront:self.startRecordBtn];
    [self.view bringSubviewToFront:self.stopRecordBtn];
}

#pragma mark - Main Func
- (void)configureCamera {
    XDXCameraModel *model = [[XDXCameraModel alloc] initWithPreviewView:self.view
                                                                 preset:AVCaptureSessionPreset1280x720
                                                              frameRate:30
                                                       resolutionHeight:720
                                                            videoFormat:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                              torchMode:AVCaptureTorchModeOff
                                                              focusMode:AVCaptureFocusModeContinuousAutoFocus
                                                           exposureMode:AVCaptureExposureModeContinuousAutoExposure
                                                              flashMode:AVCaptureFlashModeAuto
                                                       whiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance
                                                               position:AVCaptureDevicePositionBack
                                                           videoGravity:AVLayerVideoGravityResizeAspect
                                                       videoOrientation:AVCaptureVideoOrientationLandscapeRight
                                             isEnableVideoStabilization:YES];
    
    XDXCameraHandler *handler   = [[XDXCameraHandler alloc] init];
    self.cameraCaptureHandler   = handler;
    handler.delegate            = self;
    [handler configureCameraWithModel:model];
    [handler startRunning];
}

- (void)configureAudioCapture {
    XDXAudioCaptureManager *handler = [XDXAudioCaptureManager getInstance];
    handler.delegate = self;
    [handler startAudioCapture];
    self.audioCaptureHandler = handler;
}

- (void)configureAudioEncoder {
    AudioStreamBasicDescription audioDataFormat = [[XDXAudioCaptureManager getInstance] getAudioDataFormat];
    self.audioEncoder = [[XDXAduioEncoder alloc] initWithSourceFormat:audioDataFormat
                                                         destFormatID:kAudioFormatMPEG4AAC
                                                           sampleRate:44100
                                                  isUseHardwareEncode:YES];
}

- (void)configurevideoEncoder {
    // You could select h264 / h265 encoder.
    self.videoEncoder = [[XDXVideoEncoder alloc] initWithWidth:1280
                                                        height:720
                                                           fps:30
                                                       bitrate:2048
                                       isSupportRealTimeEncode:NO
                                                   encoderType:XDXH264Encoder]; // XDXH264Encoder
    self.videoEncoder.delegate = self;
    [self.videoEncoder configureEncoderWithWidth:1280 height:720];
}

- (void)configureAVMuxHandler {
    self.muxHandler = [XDXAVStreamMuxHandler sharedInstance];
    [self.muxHandler prepareForMux];
    self.muxHandler.delegate = self;
}

- (void)configureAVRecorder {
    self.recorder = [[XDXAVRecorder alloc] init];
}

#pragma mark - Button Action
- (IBAction)startRecordBtnDidClicked:(id)sender {
    int size = 0;
    char *data = (char *)[self.muxHandler getAVStreamHeadWithSize:&size];
    [self.recorder startRecordWithIsHead:YES data:data size:size];
    self.isRecording = YES;
}

- (IBAction)stopRecordBtnDidClicked:(id)sender {
    self.isRecording = NO;
    [self.recorder stopRecord];
}

#pragma mark - Delegate
#pragma mark Camera
- (void)xdxCaptureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]] == YES) {
        if (self.videoEncoder) {
            [self.videoEncoder startEncodeDataWithBuffer:sampleBuffer
                                        isNeedFreeBuffer:NO];
            
        }
        
    }
}

- (void)xdxCaptureOutput:(nonnull AVCaptureOutput *)output didDropSampleBuffer:(nonnull CMSampleBufferRef)sampleBuffer fromConnection:(nonnull AVCaptureConnection *)connection {
}


#pragma mark Audio Capture and Audio Encode
- (void)receiveAudioDataByDevice:(XDXCaptureAudioDataRef)audioDataRef {
    [self.audioEncoder encodeAudioWithSourceBuffer:audioDataRef->data
                                  sourceBufferSize:audioDataRef->size
                                               pts:audioDataRef->pts
                                   completeHandler:^(XDXAudioEncderDataRef dataRef) {
                                       if (dataRef->size > 10) {
                                           [self.muxHandler addAudioData:(uint8_t *)dataRef->data
                                                                    size:dataRef->size
                                                              channelNum:1
                                                              sampleRate:44100
                                                               timestamp:dataRef->pts];                                           
                                       }
                                       free(dataRef->data);
                                   }];
}

#pragma mark Video Encoder
- (void)receiveVideoEncoderData:(XDXVideEncoderDataRef)dataRef {
    [self.muxHandler addVideoData:dataRef->data size:(int)dataRef->size timestamp:dataRef->timestamp isKeyFrame:dataRef->isKeyFrame isExtraData:dataRef->isExtraData videoFormat:XDXMuxVideoFormatH264];
}

#pragma mark Mux
- (void)receiveAVStreamWithIsHead:(BOOL)isHead data:(uint8_t *)data size:(int)size {
    if (isHead) {
        return;
    }
    
    if (self.isRecording) {
        [self.recorder startRecordWithIsHead:NO data:(char *)data size:size];
    }
}

@end
