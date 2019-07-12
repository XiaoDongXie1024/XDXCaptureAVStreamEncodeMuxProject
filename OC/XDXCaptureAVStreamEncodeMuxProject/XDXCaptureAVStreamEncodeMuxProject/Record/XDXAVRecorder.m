//
//  XDXAVRecorder.m
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/9.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXAVRecorder.h"
#import "log4cplus.h"

@interface XDXAVRecorder () {
    FILE *m_fp;
}

@property (assign, nonatomic) BOOL      hadAVHead;
@property (strong, nonatomic) NSLock    *writeFileLock;

@end

@implementation XDXAVRecorder

#pragma mark - Lifecycle
- (instancetype)init {
    if (self = [super init]) {
        _hadAVHead      = NO;
        _writeFileLock  = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - Public
- (void)startRecordWithIsHead:(BOOL)isHead data:(char *)data size:(int)size {
    [self.writeFileLock lock];
    
    if (isHead) {
        [self openFile];
        fseek(m_fp, 0, SEEK_SET);
        self.hadAVHead = YES;
    }
    
    if (!self.hadAVHead) {
        [self.writeFileLock unlock];
        return;
    }

    if(m_fp != NULL) {
        fwrite(data, 1, size, m_fp);
    }
    
    [self.writeFileLock unlock];
}

- (void)stopRecord {
    [self.writeFileLock lock];
    [self closeFile];
    self.hadAVHead = NO;
    [self.writeFileLock unlock];
}

#pragma mark - Private
- (void)openFile {
    NSString *filePath = [self createFilePath];
    
    m_fp = fopen(filePath.UTF8String, "w+");
    if(m_fp == NULL) {
        NSLog(@"open file failed: %@",filePath);
    }
}

- (void)closeFile {
    if(m_fp != NULL) {
        fclose(m_fp);
        m_fp = NULL;
    }
}

- (NSString *)createFilePath {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"yyyy_MM_dd_HH_mm_ss";
    NSDate *today = [NSDate date];
    NSString *fileName = [dateFormatter stringFromDate:today];
    
    NSArray *searchPaths    = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                  NSUserDomainMask,
                                                                  YES);
    
    NSString *documentPath  = [searchPaths objectAtIndex:0];
    
//    // 先创建子目录. 注意,若果直接调用AudioFileCreateWithURL创建一个不存在的目录创建文件会失败
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:documentPath]) {
        [fileManager createDirectoryAtPath:documentPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString *fullFileName  = [NSString stringWithFormat:@"%@.asf",fileName];
    NSString *filePath      = [documentPath stringByAppendingPathComponent:fullFileName];
    return filePath;
}

#pragma mark - Other


@end
