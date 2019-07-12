//
//  XDXAVStreamMuxHandler.m
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/7.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXAVStreamMuxHandler.h"
#import "XDXAVPacketList.h"
#import "log4cplus.h"

#define kModuleName "XDXAVMux"

@interface XDXAVStreamMuxHandler ()
{
    /* control av stream context */
    AVFormatContext        *m_outputContext;
    AVOutputFormat         *m_outputFormat;
    
    /* current capture a/v stream */
    AVStream               *m_video_stream;
    AVStream               *m_audio_stream;
    
    /* transfer a/v packet data */
    XDXAVPacketList        *m_AudioListPack;
    XDXAVPacketList        *m_VideoListPack;
    
    /* global var */
    pthread_t              m_muxThread;
    pthread_mutex_t        m_muxLock;
    AVRational             m_basetime;
    
    /* stream head data */
    uint8_t *m_avhead_data;
    int      m_avhead_data_size;
    
    /* video extra data */
    uint8_t *m_video_extraData;
    int      m_video_extraSize;
}

@property (nonatomic, assign) BOOL isReadyForAudio;
@property (nonatomic, assign) BOOL isReadyForVideo;
@property (nonatomic, assign) BOOL isReadyForHead;

@end

@implementation XDXAVStreamMuxHandler

SingletonM

#pragma mark - C Function
void * MuxAVPacket(void *arg) {
    pthread_setname_np("XDX_MUX_THREAD");
    XDXAVStreamMuxHandler *instance = (__bridge_transfer XDXAVStreamMuxHandler *)arg;
    if(instance != nil) {
        [instance dispatchAVData];
    }
    
    return NULL;
}

#pragma mark - Lifecycle
- (instancetype)init {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instace = [super init];
        avcodec_register_all();
        av_register_all();
    });
    return _instace;
}

- (void)configureFFmpegWithFormat:(const char *)format {
    if(m_outputContext != NULL) {
        av_free(m_outputContext);
        m_outputContext = NULL;
    }
    
    m_outputContext = avformat_alloc_context();
    m_outputFormat  = av_guess_format(format, NULL, NULL);
    
    m_outputContext->oformat    = m_outputFormat;
    m_outputFormat->audio_codec = AV_CODEC_ID_NONE;
    m_outputFormat->video_codec = AV_CODEC_ID_NONE;
    m_outputContext->nb_streams = 0;
    
    m_video_stream     = avformat_new_stream(m_outputContext, NULL);
    m_video_stream->id = 0;
    m_audio_stream     = avformat_new_stream(m_outputContext, NULL);
    m_audio_stream->id = 1;
    
    log4cplus_info(kModuleName, "configure ffmpeg finish.");
}

- (void)initGlobalVar {
    m_AudioListPack    = [[XDXAVPacketList alloc] init];
    m_VideoListPack    = [[XDXAVPacketList alloc] init];
    
    _isReadyForAudio   = NO;
    _isReadyForVideo   = NO;
    _isReadyForHead    = NO;
    
    m_basetime.den     = 1000;
    m_basetime.num     = 1;
    
    m_video_extraSize  = 0;
    m_video_extraData  = NULL;
    
    m_avhead_data_size = 0;
    m_avhead_data      = NULL;
}

#pragma mark - Public
+ (instancetype)sharedInstance {
    return [[self alloc] init];
}

- (void)prepareForMux {
    pthread_mutex_init(&m_muxLock, NULL);
    
    [self initGlobalVar];
    [self configureFFmpegWithFormat:"asf"];
    
    int err = pthread_create(&m_muxThread,NULL,MuxAVPacket,(__bridge_retained void *)self);
    if(err != 0){
        log4cplus_error(kModuleName, "%s: create thread failed: %s",__func__, strerror(err));
    }
}

- (void)addVideoData:(uint8_t *)data size:(int)size timestamp:(int64_t)timestamp isKeyFrame:(BOOL)isKeyFrame isExtraData:(BOOL)isExtraData videoFormat:(XDXMuxVideoFormat)videoFormat {
    if (data == NULL || size <= 0 || timestamp < 0) {
        log4cplus_error(kModuleName, "%s: Add video data error, size:%d, timestamp:%lld",__func__,size,timestamp);
        return;
    }
    
    pthread_mutex_lock(&m_muxLock);
    
    if (!self.isReadyForVideo && isExtraData) {
        [self configureVideoStreamWithVideoFormat:videoFormat
                                        extraData:data
                                    extraDataSize:size];
    }
    
    BOOL isUpdateExtraData = NO;
    if (isExtraData) {
        int lastSize = m_video_extraSize;
        isUpdateExtraData = [self updateExtraData:data size:size videoFormat:XDXMuxVideoFormatH264];
        if (isUpdateExtraData && lastSize != 0) {
            [self productStreamHead];
            log4cplus_info(kModuleName, "%s: Update extra data, last:%d -> now:%d",__func__,lastSize, size);
        }
        
        pthread_mutex_unlock(&m_muxLock);
        return;
    }
    pthread_mutex_unlock(&m_muxLock);
    
    XDXMuxMediaList item = {0};
    item.data = (AVPacket *)av_malloc(sizeof(AVPacket));
    av_init_packet(item.data);
    item.extraDataHasChanged = isUpdateExtraData;
    
    if(isKeyFrame) { // you could add SEI before I frame
        item.data->data = (uint8_t*)av_malloc(m_video_extraSize+size);
        memcpy(item.data->data, m_video_extraData, m_video_extraSize);
        memcpy(item.data->data+m_video_extraSize, data, size);
        item.data->size = m_video_extraSize+size;
    }else {
        item.data->data = (uint8_t*)av_malloc(size);
        item.data->size = size;
        memcpy(item.data->data, data, size);
    }
    
    static int64_t lastPtsTime = 0;
    int64_t duration = timestamp - lastPtsTime;
    if(duration > 0) {
        lastPtsTime = timestamp;
    }
    
    item.timeStamp          = timestamp;
    item.datatype           = XDXMuxVideoType;
    item.data->duration     = (int)duration;
    item.data->pts          = timestamp;
    item.data->dts          = timestamp;
    item.data->stream_index = 0;
    item.data->flags        = isKeyFrame;
    item.data->pos          = 0;
    
    static uint64_t lastTimeStamp = 0;
    if (lastTimeStamp == 0) {
        lastTimeStamp = item.timeStamp;
    }else{
        if (item.timeStamp > lastTimeStamp) {
            lastTimeStamp = item.timeStamp;
        }else{
            av_free(item.data->data);
            av_free(item.data);
            pthread_mutex_unlock(&m_muxLock);
            log4cplus_error(kModuleName, "%s: wrong video packet with error timestamp = %llu",__func__,item.timeStamp);
            return;
        }
    }
    
    BOOL isSuccess = [m_VideoListPack pushData:item];
    if(!isSuccess) {
        av_free(item.data->data);
        av_free(item.data);
        log4cplus_error(kModuleName, "%s: video list is full, push video packet filured!",__func__);
    }
    
    pthread_mutex_unlock(&m_muxLock);
}


- (void)addAudioData:(uint8_t *)data size:(int)size channelNum:(int)channelNum sampleRate:(int)sampleRate timestamp:(int64_t)timestamp {
    if (data == NULL || size <= 0 || timestamp < 0) {
        log4cplus_error(kModuleName, "%s: Add audio data error, size:%d, timestamp:%lld",__func__,size,timestamp);
        return;
    }
    
    pthread_mutex_lock(&m_muxLock);
    
    if (!self.isReadyForAudio) {
        [self configureAudioStreamWithChannelNum:channelNum sampleRate:sampleRate];
        pthread_mutex_unlock(&m_muxLock);
        return;
    }
    
    if(!self.isReadyForVideo){
        log4cplus_error("record", "Video is not ready, drop audio, ts:%llu\n",timestamp);
        pthread_mutex_unlock(&m_muxLock);
        return;
    }
    
    // packet
    XDXMuxMediaList item = {0};
    item.data = (AVPacket *)av_malloc(sizeof(AVPacket));
    av_init_packet(item.data);
    
    item.data->data = (uint8_t*)av_malloc(size);
    memcpy(item.data->data, data, size);
    
    item.data->size         = size;
    item.data->duration     = 1024;
    item.data->pts          = item.data->dts = timestamp;
    item.timeStamp          = timestamp;
    item.datatype           = XDXMuxAudioType;
    item.data->stream_index = 1;
    item.data->flags        = 1;
    item.data->pos          = 0;
    
    static uint64_t lastTimeStamp = 0;
    if (lastTimeStamp == 0) {
        lastTimeStamp = item.timeStamp;
    }else{
        if (item.timeStamp > lastTimeStamp) {
            lastTimeStamp = item.timeStamp;
        }else {
            log4cplus_error("record", "Audio packet time error,curr time:%lld < lastTime:%lld\n",item.timeStamp,lastTimeStamp);
            av_free(item.data->data);
            av_free(item.data);
            pthread_mutex_unlock(&m_muxLock);
            return;
        }
    }
    
    BOOL isSuccess = [m_AudioListPack pushData:item];
    if(!isSuccess) {
        log4cplus_error("record", "audio list overflow, push to audio list failed %llu",timestamp);
        av_free(item.data->data);
        av_free(item.data);
    }

    pthread_mutex_unlock(&m_muxLock);
}


- (void *)getAVStreamHeadWithSize:(int *)size {
    *size = m_avhead_data_size;
    return m_avhead_data;
}

- (int)getAVStreamHeadSize {
    return m_avhead_data_size;
}
void printfBuffer1(uint8_t* buf, int size, char* name) {
    int i = 0;
    printf("%s:", name);
    for(i = 0; i < size; i++){
        printf("%02x,", buf[i]);
    }
    printf("\n");
}
#pragma mark - Private
- (void)productStreamHead {
    log4cplus_debug("record", "%s,line:%d",__func__,__LINE__);
    
    if (m_outputFormat->video_codec == AV_CODEC_ID_NONE) {
        log4cplus_error(kModuleName, "%s: video codec is NULL.",__func__);
        return;
    }
    
    if(m_outputFormat->audio_codec == AV_CODEC_ID_NONE) {
        log4cplus_error(kModuleName, "%s: audio codec is NULL.",__func__);
        return;
    }
    
    /* prepare header and save header data in a stream */
    if (avio_open_dyn_buf(&m_outputContext->pb) < 0) {
        avio_close_dyn_buf(m_outputContext->pb, NULL);
        log4cplus_error(kModuleName, "%s: AVFormat_HTTP_FF_OPEN_DYURL_ERROR.",__func__);
        return;
    }
        
    /*
     * HACK to avoid mpeg ps muxer to spit many underflow errors
     * Default value from FFmpeg
     * Try to set it use configuration option
     */
    m_outputContext->max_delay = (int)(0.7*AV_TIME_BASE);
        
    int result = avformat_write_header(m_outputContext,NULL);
    if (result < 0) {
        log4cplus_error(kModuleName, "%s: Error writing output header, res:%d",__func__,result);
        return;
    }
        
    uint8_t * output = NULL;
    int len = avio_close_dyn_buf(m_outputContext->pb, (uint8_t **)(&output));
    if(len > 0 && output != NULL) {
        av_free(output);
        
        self.isReadyForHead = YES;
        
        if (m_avhead_data) {
            free(m_avhead_data);
        }
        m_avhead_data_size = len;
        m_avhead_data = (uint8_t *)malloc(len);
        memcpy(m_avhead_data, output, len);
        
        if ([self.delegate respondsToSelector:@selector(receiveAVStreamWithIsHead:data:size:)]) {
            [self.delegate receiveAVStreamWithIsHead:YES data:output size:len];
        }
        
        log4cplus_error(kModuleName, "%s: create head length = %d",__func__, len);
    }else{
        self.isReadyForHead = NO;
        log4cplus_error(kModuleName, "%s: product stream header failed.",__func__);
    }
}


- (void)configureVideoStreamWithVideoFormat:(XDXMuxVideoFormat)videoFormat extraData:(uint8_t *)extraData extraDataSize:(int)extraDataSize {
    if (m_outputContext == NULL) {
        log4cplus_error(kModuleName, "%s: m_outputContext is null",__func__);
        return;
    }
    
    if(m_outputFormat == NULL){
        log4cplus_error(kModuleName, "%s: m_outputFormat is null",__func__);
        return;
    }

    AVFormatContext *formatContext = avformat_alloc_context();
    AVStream *stream = NULL;
    if(XDXMuxVideoFormatH264 == videoFormat) {
        AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_H264);
        stream = avformat_new_stream(formatContext, codec);
        stream->codecpar->codec_id = AV_CODEC_ID_H264;
    }else if(XDXMuxVideoFormatH265 == videoFormat) {
        AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_HEVC);
        stream = avformat_new_stream(formatContext, codec);
        stream->codecpar->codec_tag      = MKTAG('h', 'e', 'v', 'c');
        stream->codecpar->profile        = FF_PROFILE_HEVC_MAIN;
        stream->codecpar->format         = AV_PIX_FMT_YUV420P;
        stream->codecpar->codec_id       = AV_CODEC_ID_HEVC;
    }
    
    stream->codecpar->format             = AV_PIX_FMT_YUVJ420P;
    stream->codecpar->codec_type         = AVMEDIA_TYPE_VIDEO;
    stream->codecpar->width              = 1280;
    stream->codecpar->height             = 720;
    stream->codecpar->bit_rate           = 1024*1024;
    stream->time_base.den                = 1000;
    stream->time_base.num                = 1;
    stream->time_base                    = (AVRational){1, 1000};
    stream->codec->flags                |= AV_CODEC_FLAG_GLOBAL_HEADER;
    
    memcpy(m_video_stream, stream, sizeof(AVStream));
    
    if(extraData) {
        int newExtraDataSize = extraDataSize + AV_INPUT_BUFFER_PADDING_SIZE;
        m_video_stream->codecpar->extradata_size = extraDataSize;
        m_video_stream->codecpar->extradata      = (uint8_t *)av_mallocz(newExtraDataSize);
        memcpy(m_video_stream->codecpar->extradata, extraData, extraDataSize);
    }
    
    av_free(stream);

    m_outputContext->video_codec_id = m_video_stream->codecpar->codec_id;
    m_outputFormat->video_codec     = m_video_stream->codecpar->codec_id;
    
    self.isReadyForVideo = YES;
    
    [self productStreamHead];
}



- (BOOL)updateExtraData:(uint8_t *)extraData size:(int)size videoFormat:(XDXMuxVideoFormat)videoFormat {
    BOOL updateVideoStream = NO;
    if(m_video_extraData == NULL) {
        updateVideoStream = YES;
        m_video_extraSize = size;
        m_video_extraData = (uint8_t*)malloc(size);
        memcpy(m_video_extraData, extraData, size);
        log4cplus_info(kModuleName, "%s: create extra data, size:%d",__func__,size);
    }else{
        if (m_video_extraSize != size) {
            updateVideoStream = YES;
        }else {
            if(memcmp(m_video_extraData,extraData,size) != 0){
                updateVideoStream = YES;
            }
        }
        
        if (updateVideoStream) {
            m_video_extraSize = size;
            memcpy(m_video_extraData, extraData, size);
            AVCodecParameters *codecParameters = m_video_stream->codecpar;
            uint64_t extra_size_x = (uint64_t)size + AV_INPUT_BUFFER_PADDING_SIZE;
            codecParameters->extradata          = (uint8_t *)av_mallocz((int)extra_size_x);
            codecParameters->extradata_size     = size;
            memcpy(codecParameters->extradata, extraData, size);
        }
    }
    
    return updateVideoStream;
}

- (void)configureAudioStreamWithChannelNum:(int)channelNum sampleRate:(int)sampleRate {
    AVFormatContext *formatContext  = avformat_alloc_context();
    AVCodec         *codec          = avcodec_find_encoder(AV_CODEC_ID_AAC);
    AVStream        *stream         = avformat_new_stream(formatContext, codec);
    
    stream->index         = 1;
    stream->id            = 1;
    stream->duration      = 0;
    stream->time_base.num = 1;
    stream->time_base.den = 1000;
    stream->start_time    = 0;
    stream->priv_data     = NULL;
    
    stream->codecpar->codec_type     = AVMEDIA_TYPE_AUDIO;
    stream->codecpar->codec_id       = AV_CODEC_ID_AAC;
    stream->codecpar->format         = AV_SAMPLE_FMT_S16;
    stream->codecpar->sample_rate    = sampleRate;
    stream->codecpar->channels       = channelNum;
    stream->codecpar->bit_rate       = 0;
    stream->codecpar->extradata_size = 2;
    stream->codecpar->extradata      = (uint8_t *)malloc(2);
    stream->time_base.den  = 25;
    stream->time_base.num  = 1;
    
    /*
     * why we put extra data here for audio: when save to MP4 file, the player can not decode it correctly
     * http://ffmpeg-users.933282.n4.nabble.com/AAC-decoder-td1013071.html
     * http://ffmpeg.org/doxygen/trunk/mpeg4audio_8c.html#aa654ec3126f37f3b8faceae3b92df50e
     * extra data have 16 bits:
     * Audio object type - normally 5 bits, but 11 bits if AOT_ESCAPE
     * Sampling index - 4 bits
     * if (Sampling index == 15)
     * Sample rate - 24 bits
     * Channel configuration - 4 bits
     * last reserved- 3 bits
     * for exmpale:  "Low Complexity Sampling frequency 44100Hz, 1 channel mono":
     * AOT_LC == 2 -> 00010
     -              * 44.1kHz == 4 -> 0100
     +              * 44.1kHz == 4 -> 0100  48kHz == 3 -> 0011
     * mono == 1 -> 0001
     * so extra data: 00010 0100 0001 000 ->0x12 0x8
     +                  00010 0011 0001 000 ->0x11 0x88
     +
     */
    
    if (stream->codecpar->sample_rate == 44100) {
        stream->codecpar->extradata[0] = 0x12;
        //iRig mic HD have two chanel 0x11
        if(channelNum == 1)
            stream->codecpar->extradata[1] = 0x8;
        else
            stream->codecpar->extradata[1] = 0x10;
    }else if (stream->codecpar->sample_rate == 48000) {
        stream->codecpar->extradata[0] = 0x11;
        //iRig mic HD have two chanel 0x11
        if(channelNum == 1)
            stream->codecpar->extradata[1] = 0x88;
        else
            stream->codecpar->extradata[1] = 0x90;
    }else if (stream->codecpar->sample_rate == 32000){
        stream->codecpar->extradata[0] = 0x12;
        if (channelNum == 1)
            stream->codecpar->extradata[1] = 0x88;
        else
            stream->codecpar->extradata[1] = 0x90;
    }
    else if (stream->codecpar->sample_rate == 16000){
        stream->codecpar->extradata[0] = 0x14;
        if (channelNum == 1)
            stream->codecpar->extradata[1] = 0x8;
        else
            stream->codecpar->extradata[1] = 0x10;
    }else if(stream->codecpar->sample_rate == 8000){
        stream->codecpar->extradata[0] = 0x15;
        if (channelNum == 1)
            stream->codecpar->extradata[1] = 0x88;
        else
            stream->codecpar->extradata[1] = 0x90;
    }
    
    stream->codec->flags|= AV_CODEC_FLAG_GLOBAL_HEADER;
    
    memcpy(m_audio_stream, stream, sizeof(AVStream));
    
    av_free(stream);
    
    m_outputContext->audio_codec_id = stream->codecpar->codec_id;
    m_outputFormat->audio_codec     = stream->codecpar->codec_id;
    
    self.isReadyForAudio = YES;

    [self productStreamHead];
}

#pragma mark Mux
- (void)dispatchAVData {
    XDXMuxMediaList audioPack;
    XDXMuxMediaList videoPack;
    
    memset(&audioPack, 0, sizeof(XDXMuxMediaList));
    memset(&videoPack, 0, sizeof(XDXMuxMediaList));
    
    [m_AudioListPack reset];
    [m_VideoListPack reset];

    while (true) {
        int videoCount = [m_VideoListPack count];
        int audioCount = [m_AudioListPack count];
        if(videoCount == 0 || audioCount == 0) {
            usleep(5*1000);
            log4cplus_debug(kModuleName, "%s: Mux dispatch list: v:%d, a:%d",__func__,videoCount, audioCount);
            continue;
        }
        
        if(audioPack.timeStamp == 0) {
            [m_AudioListPack popData:&audioPack];
        }
        
        if(videoPack.timeStamp == 0) {
            [m_VideoListPack popData:&videoPack];
        }
        
        if(audioPack.timeStamp >= videoPack.timeStamp) {
            log4cplus_debug(kModuleName, "%s: Mux dispatch input video time stamp = %llu",__func__,videoPack.timeStamp);
            
            if(videoPack.data != NULL && videoPack.data->data != NULL){
                [self addVideoPacket:videoPack.data
                           timestamp:videoPack.timeStamp
                 extraDataHasChanged:videoPack.extraDataHasChanged];
                
                av_free(videoPack.data->data);
                av_free(videoPack.data);
            }else{
                log4cplus_error(kModuleName, "%s: Mux Video AVPacket data abnormal",__func__);
            }
            videoPack.timeStamp = 0;
        }else {
            log4cplus_debug(kModuleName, "%s: Mux dispatch input audio time stamp = %llu",__func__,audioPack.timeStamp);
            
            if(audioPack.data != NULL && audioPack.data->data != NULL) {
                [self addAudioPacket:audioPack.data
                           timestamp:audioPack.timeStamp];
                av_free(audioPack.data->data);
                av_free(audioPack.data);
            }else {
                log4cplus_error(kModuleName, "%s: Mux audio AVPacket data abnormal",__func__);
            }
            
            audioPack.timeStamp = 0;
        }
    }
}

- (void)addVideoPacket:(AVPacket *)packet timestamp:(u_int64_t)timestamp extraDataHasChanged:(BOOL)extraDataHasChanged {
    if (packet == NULL)
        return;
    
    pthread_mutex_lock(&m_muxLock);
    if(self.isReadyForHead) {
        AVPacket outputPacket;
        av_init_packet(&outputPacket);
        
        outputPacket.size         = packet->size;
        outputPacket.data         = packet->data;
        outputPacket.flags        = packet->flags;
        outputPacket.pts          = av_rescale_q(packet->pts,m_basetime ,m_video_stream->time_base);
        outputPacket.dts          = outputPacket.pts;
        outputPacket.duration     = av_rescale_q(packet->duration,m_basetime ,m_video_stream->time_base);
        outputPacket.stream_index = 0;
        packet->stream_index      = 0;
        
        log4cplus_debug(kModuleName, "%s: Add video input packet = %llu timestamp = %llu",__func__,packet->pts,outputPacket.pts);
        [self productAVDataPacket:&outputPacket extraDataHasChanged:extraDataHasChanged];
    }
    pthread_mutex_unlock(&m_muxLock);
}

- (void)addAudioPacket:(AVPacket *)packet timestamp:(u_int64_t)timestamp {
    if (packet == NULL)
        return;
    
    pthread_mutex_lock(&m_muxLock);
    
    if(self.isReadyForHead) {
        AVPacket outputPacket;
        av_init_packet(&outputPacket);
        
        outputPacket.size         = packet->size;
        outputPacket.data         = packet->data;
        outputPacket.flags        = packet->flags;
        outputPacket.pts          = av_rescale_q(packet->pts, m_basetime, m_audio_stream->time_base);
        outputPacket.dts          = outputPacket.pts;
        outputPacket.duration     = av_rescale_q(packet->duration,m_basetime ,m_audio_stream->time_base);
        outputPacket.stream_index = 1;
        packet->stream_index      = 1;
        
        log4cplus_debug(kModuleName, "%s: Add audio timestamp = %llu",__func__,outputPacket.pts);
        [self productAVDataPacket:&outputPacket extraDataHasChanged:NO];
    }
    
    pthread_mutex_unlock(&m_muxLock);
}

- (void)productAVDataPacket:(AVPacket *)packet extraDataHasChanged:(BOOL)extraDataHasChanged {
    BOOL    isVideoIFrame = NO;
    uint8_t *output       = NULL;
    int     len           = 0;
    
    if (avio_open_dyn_buf(&m_outputContext->pb) < 0) {
        return;
    }
    
    if(packet->stream_index == 0 && packet->flags != 0) {
        isVideoIFrame = YES;
    }
    
    if (av_write_frame(m_outputContext, packet) < 0) {
        avio_close_dyn_buf(m_outputContext->pb, (uint8_t **)(&output));
        if(output != NULL)
            free(output);
        
        log4cplus_error(kModuleName, "%s: Error writing output data",__func__);
        return;
    }
    
    
    len = avio_close_dyn_buf(m_outputContext->pb, (uint8_t **)(&output));
    
    if(len == 0 || output == NULL) {
        log4cplus_debug(kModuleName, "%s: mux len:%d or data abnormal",__func__,len);
        if(output != NULL)
            av_free(output);
        return;
    }
        
    if ([self.delegate respondsToSelector:@selector(receiveAVStreamWithIsHead:data:size:)]) {
        [self.delegate receiveAVStreamWithIsHead:NO data:output size:len];
    }
    
    if(output != NULL)
        av_free(output);
}


#pragma mark - Other
@end
