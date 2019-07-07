//
//  XDXAduioEncoder.m
//  XDXAudioUnitCapture
//
//  Created by 小东邪 on 2019/5/12.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXAduioEncoder.h"
#import "XDXAudioCaptureManager.h"

struct XDXConverterInfo {
    UInt32   sourceChannelsPerFrame;
    UInt32   sourceDataSize;
    void     *sourceBuffer;
};

typedef struct XDXConverterInfo XDXConverterInfoType;

const static NSString *kModuleName = @"Audio Encoder:";

@interface XDXAduioEncoder ()

@end

@implementation XDXAduioEncoder

#pragma mark - Encode Callback
OSStatus EncodeConverterComplexInputDataProc(AudioConverterRef              inAudioConverter,
                                             UInt32                         *ioNumberDataPackets,
                                             AudioBufferList                *ioData,
                                             AudioStreamPacketDescription   **outDataPacketDescription,
                                             void                           *inUserData) {
    XDXConverterInfoType *info = (XDXConverterInfoType *)inUserData;
    ioData->mNumberBuffers              = 1;
    ioData->mBuffers[0].mData           = info->sourceBuffer;
    ioData->mBuffers[0].mNumberChannels = info->sourceChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize   = info->sourceDataSize;
    
    return noErr;
}

#pragma mark - Public
- (instancetype)initWithSourceFormat:(AudioStreamBasicDescription)sourceFormat destFormatID:(AudioFormatID)destFormatID sampleRate:(float)sampleRate isUseHardwareEncode:(BOOL)isUseHardwareEncode {
    if (self = [super init]) {
        mSourceFormat   = sourceFormat;
        mAudioConverter = [self configureEncoderBySourceFormat:sourceFormat
                                                    destFormat:&mDestinationFormat
                                                  destFormatID:destFormatID
                                                    sampleRate:sampleRate
                                           isUseHardwareEncode:isUseHardwareEncode];
    }
    return self;
}

- (void)encodeAudioWithSourceBuffer:(void *)sourceBuffer sourceBufferSize:(UInt32)sourceBufferSize completeHandler:(void(^)(AudioBufferList *destBufferList, UInt32 outputPackets, AudioStreamPacketDescription *outputPacketDescriptions))completeHandler {
    [self encodeFormatByConverter:mAudioConverter
                     sourceBuffer:sourceBuffer
                 sourceBufferSize:sourceBufferSize
                     sourceFormat:mSourceFormat
                             dest:mDestinationFormat
                  completeHandler:completeHandler];
}

- (void)freeEncoder {
    if (mAudioConverter) {
        AudioConverterDispose(mAudioConverter);
        mAudioConverter = NULL;
    }
}

#pragma mark - Private
- (AudioConverterRef)configureEncoderBySourceFormat:(AudioStreamBasicDescription)sourceFormat destFormat:(AudioStreamBasicDescription *)destFormat destFormatID:(AudioFormatID)destFormatID sampleRate:(float)sampleRate isUseHardwareEncode:(BOOL)isUseHardwareEncode {
    UInt32 size;
    
    AudioStreamBasicDescription destinationFormat = {};
    destinationFormat.mSampleRate = sampleRate;
    if (destFormatID == kAudioFormatLinearPCM) {
        NSLog(@"Not get PCM format after encoding !");
        return NULL;
    } else {
        destinationFormat.mFormatID = destFormatID;
        
        // For iLBC, the number of channels must be 1.
        destinationFormat.mChannelsPerFrame = (destFormatID == kAudioFormatiLBC ? 1 : sourceFormat.mChannelsPerFrame);
        
        // Use AudioFormat API to fill out the rest of the description.
        size = sizeof(destinationFormat);
        if (![self checkError:AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &destinationFormat) withErrorString:@"AudioFormatGetProperty couldn't fill out the destination data format"]) {
            return NULL;
        }
    }
    memcpy(destFormat, &destinationFormat, sizeof(AudioStreamBasicDescription));
    
    printf("Source File format:\n");
    [XDXAduioEncoder printAudioStreamBasicDescription:sourceFormat];
    printf("Destination File format:\n");
    [XDXAduioEncoder printAudioStreamBasicDescription:destinationFormat];
    
    // encoder conut by channels.
    AudioClassDescription requestedCodecs[destinationFormat.mChannelsPerFrame];
    const OSType subtype = destFormatID;
    for (int i = 0; i < destinationFormat.mChannelsPerFrame; i++) {
        AudioClassDescription codec = {
            kAudioEncoderComponentType,
            subtype,
            isUseHardwareEncode ? kAppleHardwareAudioCodecManufacturer : kAppleSoftwareAudioCodecManufacturer,
        };
        requestedCodecs[i] = codec;
    }
    
    // Create the AudioConverterRef.
    AudioConverterRef converter = NULL;
    if (![self checkError:AudioConverterNewSpecific(&sourceFormat, &destinationFormat, destinationFormat.mChannelsPerFrame, requestedCodecs, &converter) withErrorString:@"AudioConverterNew failed"]) {
        return NULL;
    }else {
        printf("Audio converter create successful \n");
    }
    
    /*
     If encoding to AAC set the bitrate kAudioConverterEncodeBitRate is a UInt32 value containing
     the number of bits per second to aim for when encoding data when you explicitly set the bit rate
     and the sample rate, this tells the encoder to stick with both bit rate and sample rate
     but there are combinations (also depending on the number of channels) which will not be allowed
     if you do not explicitly set a bit rate the encoder will pick the correct value for you depending
     on samplerate and number of channels bit rate also scales with the number of channels,
     therefore one bit rate per sample rate can be used for mono cases and if you have stereo or more,
     you can multiply that number by the number of channels.
     */
    
    if (destinationFormat.mFormatID == kAudioFormatMPEG4AAC) {
        UInt32 outputBitRate = 64000;
        
        UInt32 propSize = sizeof(outputBitRate);
        
        if (destinationFormat.mSampleRate >= 44100) {
            outputBitRate = 192000;
        } else if (destinationFormat.mSampleRate < 22000) {
            outputBitRate = 32000;
        }
        outputBitRate *= destinationFormat.mChannelsPerFrame;
        
        // Set the bit rate depending on the sample rate chosen.
        if (![self checkError:AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, propSize, &outputBitRate) withErrorString:@"AudioConverterSetProperty kAudioConverterEncodeBitRate failed!"]) {
            return NULL;
        }
        
        // Get it back and print it out.
        AudioConverterGetProperty(converter, kAudioConverterEncodeBitRate, &propSize, &outputBitRate);
        printf ("AAC Encode Bitrate: %u\n", (unsigned int)outputBitRate);
    }
    
    /*
     Can the Audio Converter resume after an interruption?
     this property may be queried at any time after construction of the Audio Converter after setting its output format
     there's no clear reason to prefer construction time, interruption time, or potential resumption time but we prefer
     construction time since it means less code to execute during or after interruption time.
     */
    BOOL canResumeFromInterruption = YES;
    UInt32 canResume = 0;
    size = sizeof(canResume);
    OSStatus error = AudioConverterGetProperty(converter, kAudioConverterPropertyCanResumeFromInterruption, &size, &canResume);
    
    if (error == noErr) {
        /*
         we recieved a valid return value from the GetProperty call
         if the property's value is 1, then the codec CAN resume work following an interruption
         if the property's value is 0, then interruptions destroy the codec's state and we're done
         */
        
        if (canResume == 0) {
            canResumeFromInterruption = NO;
        }
        
        printf("Audio Converter %s continue after interruption!\n", (!canResumeFromInterruption ? "CANNOT" : "CAN"));
        
    } else {
        /*
         if the property is unimplemented (kAudioConverterErr_PropertyNotSupported, or paramErr returned in the case of PCM),
         then the codec being used is not a hardware codec so we're not concerned about codec state
         we are always going to be able to resume conversion after an interruption
         */
        
        if (error == kAudioConverterErr_PropertyNotSupported) {
            printf("kAudioConverterPropertyCanResumeFromInterruption property not supported - see comments in source for more info.\n");
            
        } else {
            printf("AudioConverterGetProperty kAudioConverterPropertyCanResumeFromInterruption result %d, paramErr is OK if PCM\n", (int)error);
        }
        
        error = noErr;
    }
    
    return converter;
}


- (void)encodeFormatByConverter:(AudioConverterRef)audioConverter sourceBuffer:(void *)sourceBuffer sourceBufferSize:(UInt32)sourceBufferSize sourceFormat:(AudioStreamBasicDescription)sourceFormat dest:(AudioStreamBasicDescription)destFormat completeHandler:(void(^)(AudioBufferList *destBufferList, UInt32 outputPackets, AudioStreamPacketDescription *outputPacketDescriptions))completeHandler {
    
    UInt32 outputSizePerPacket = destFormat.mBytesPerPacket;
    if (outputSizePerPacket == 0) {
        // if the destination format is VBR, we need to get max size per packet from the converter
        UInt32 size = sizeof(outputSizePerPacket);
        if (![self checkError:AudioConverterGetProperty(audioConverter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &outputSizePerPacket) withErrorString:@"AudioConverterGetProperty kAudioConverterPropertyMaximumOutputPacketSize failed!"]) {
            return;
        }
    }
    
    UInt32 numberOutputPackets = 1;
    UInt32 theOutputBufferSize = sourceBufferSize;
    AudioStreamPacketDescription outputPacketDescriptions;
    
    // Set up output buffer list.
    AudioBufferList fillBufferList = {};
    fillBufferList.mNumberBuffers = 1;
    fillBufferList.mBuffers[0].mNumberChannels  = destFormat.mChannelsPerFrame;
    fillBufferList.mBuffers[0].mDataByteSize    = theOutputBufferSize;
    fillBufferList.mBuffers[0].mData            = malloc(theOutputBufferSize * sizeof(char));
    
    XDXConverterInfoType userInfo   = {0};
    userInfo.sourceBuffer           = sourceBuffer;
    userInfo.sourceDataSize         = sourceBufferSize;
    userInfo.sourceChannelsPerFrame = sourceFormat.mChannelsPerFrame;
    
    // Convert data
    UInt32 ioOutputDataPackets = numberOutputPackets;
    OSStatus status = AudioConverterFillComplexBuffer(audioConverter,
                                                      EncodeConverterComplexInputDataProc,
                                                      &userInfo,
                                                      &ioOutputDataPackets,
                                                      &fillBufferList,
                                                      &outputPacketDescriptions);
    
    
    
    // if interrupted in the process of the conversion call, we must handle the error appropriately
    if (status != noErr) {
        if (status == kAudioConverterErr_HardwareInUse) {
            printf("Audio Converter returned kAudioConverterErr_HardwareInUse!\n");
        } else {
            if (![self checkError:status withErrorString:@"AudioConverterFillComplexBuffer error!"]) {
                return;
            }
        }
    } else {
        if (ioOutputDataPackets == 0) {
            // This is the EOF condition.
            status = noErr;
        }
        
        completeHandler(&fillBufferList, ioOutputDataPackets, &outputPacketDescriptions);
    }
}

- (void)writeChannelLayoutWithConverter:(AudioConverterRef)converter sourceFile:(AudioFileID)sourceFileID destinationFile:(AudioFileID)destinationFileID {
    UInt32 layoutSize = 0;
    bool layoutFromConverter = true;
    
    OSStatus error = AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &layoutSize, NULL);
    
    // if the Audio Converter doesn't have a layout see if the input file does
    if (error || 0 == layoutSize) {
        error = AudioFileGetPropertyInfo(sourceFileID, kAudioFilePropertyChannelLayout, &layoutSize, NULL);
        layoutFromConverter = false;
    }
    
    if (noErr == error && 0 != layoutSize) {
        char* layout = malloc(layoutSize * sizeof(char));
        
        if (layoutFromConverter) {
            error = AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &layoutSize, layout);
            if (error) printf("Could not Get kAudioConverterOutputChannelLayout from Audio Converter!\n");
        } else {
            error = AudioFileGetProperty(sourceFileID, kAudioFilePropertyChannelLayout, &layoutSize, layout);
            if (error) printf("Could not Get kAudioFilePropertyChannelLayout from source file!\n");
        }
        
        if (noErr == error) {
            error = AudioFileSetProperty(destinationFileID, kAudioFilePropertyChannelLayout, layoutSize, layout);
            if (noErr == error) {
                printf("Writing channel layout to destination file: %u\n", (unsigned int)layoutSize);
            } else {
                printf("Even though some formats have layouts, some files don't take them and that's OK\n");
            }
        }
        
        free(layout);
    }
}


- (BOOL)checkError:(OSStatus)error withErrorString:(NSString *)string {
    if (error == noErr) {
        return YES;
    }
    
    NSError *err = [NSError errorWithDomain:@"AudioFileConvertOperationErrorDomain" code:error userInfo:@{NSLocalizedDescriptionKey : string}];
    NSLog(@"%@ %s - %@",kModuleName, __func__, err);
    return NO;
}


+ (void)printAudioStreamBasicDescription:(AudioStreamBasicDescription)asbd {
    char formatID[5];
    UInt32 mFormatID = CFSwapInt32HostToBig(asbd.mFormatID);
    bcopy (&mFormatID, formatID, 4);
    formatID[4] = '\0';
    printf("Sample Rate:         %10.0f\n",  asbd.mSampleRate);
    printf("Format ID:           %10s\n",    formatID);
    printf("Format Flags:        %10X\n",    (unsigned int)asbd.mFormatFlags);
    printf("Bytes per Packet:    %10d\n",    (unsigned int)asbd.mBytesPerPacket);
    printf("Frames per Packet:   %10d\n",    (unsigned int)asbd.mFramesPerPacket);
    printf("Bytes per Frame:     %10d\n",    (unsigned int)asbd.mBytesPerFrame);
    printf("Channels per Frame:  %10d\n",    (unsigned int)asbd.mChannelsPerFrame);
    printf("Bits per Channel:    %10d\n",    (unsigned int)asbd.mBitsPerChannel);
    printf("\n");
}

@end
