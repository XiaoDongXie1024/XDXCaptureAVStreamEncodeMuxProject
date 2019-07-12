//
//  XDXAVPacketList.m
//  XDXCaptureAVStreamEncodeMuxProject
//
//  Created by 小东邪 on 2019/7/8.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXAVPacketList.h"
#include <vector>
#include <pthread.h>

#define MAX_MEDIALIST_LENGTH    100

using namespace std;

@interface XDXAVPacketList ()
{
    std::vector<XDXMuxMediaList> m_totalList;
    
    u_int64_t        m_nextTimeStamp;
    pthread_mutex_t  m_lock;
    
    int m_count;
    int m_static;
}

@end

@implementation XDXAVPacketList

#pragma mark - Lifecycle
- (instancetype)init {
    if (self = [super init]) {
        pthread_mutex_init(&m_lock, NULL);
        [self reset];
    }
    return self;
}

- (void)dealloc {
    pthread_mutex_destroy(&m_lock);
}


#pragma mark - Public
- (BOOL)pushData:(XDXMuxMediaList)data {
    BOOL result = NO;
    
    pthread_mutex_lock(&m_lock);
    
    if(m_count < MAX_MEDIALIST_LENGTH) {
        if(m_count == 0)
            m_nextTimeStamp = data.timeStamp;
        
        m_totalList.push_back(data);
        m_count ++;
        
        if(m_static < m_count)
            m_static = m_count;
        
        result = YES;
    }
    
    pthread_mutex_unlock(&m_lock);
    
    return result;
}

- (void)popData:(XDXMuxMediaList *)mediaList {
    pthread_mutex_lock(&m_lock);
    
    if (m_count <= 0) {
        pthread_mutex_unlock(&m_lock);
        return;
    }
    
    vector<XDXMuxMediaList>::iterator iterator;
    
    iterator = m_totalList.begin();
    mediaList->timeStamp = (*iterator).timeStamp;
    mediaList->data      = (*iterator).data;
    mediaList->datatype  = (*iterator).datatype;
    
    m_totalList.erase (iterator);
    m_count --;
    
    if(m_count == 0) {
        m_nextTimeStamp = 0;
    }else {
        iterator = m_totalList.begin();
        m_nextTimeStamp = mediaList->timeStamp;
    }
    
    pthread_mutex_unlock(&m_lock);
}

- (void)reset {
    pthread_mutex_lock(&m_lock);
    //m_totalList.clear();
    m_count = 0;
    m_nextTimeStamp = 0;
    m_static = 0;
    pthread_mutex_unlock(&m_lock);
}

- (int)count {
    int count = 0;
    pthread_mutex_lock(&m_lock);
    count = m_count;
    pthread_mutex_unlock(&m_lock);
    return count;
}

- (void)flush {
     m_totalList.clear();
}

#pragma mark - Private

#pragma mark - Other

@end
