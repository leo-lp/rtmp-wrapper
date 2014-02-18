//
//  RtmpWrapper.m
//  RtmpWrapper
//
//  Created by Min Kim on 9/30/13.
//  Copyright (c) 2013 iFactory Lab Limited. All rights reserved.
//

#import "RtmpWrapper.h"
#import <librtmp/rtmp.h>
#import <librtmp/log.h>
#import "IFTimeoutBlock.h"

const NSUInteger kMaxBufferSizeInKbyte = 500; // kb
const char *kOpenQueue = "com.ifactory.lab.rtmp.open.queue";
NSString *const kErrorDomain = @"com.ifactory.lab.rtmp.wrapper";

@interface RtmpWrapper () {
  RTMP *rtmp_;
  BOOL connected_;
  BOOL writeQueueInUse_;
  NSMutableArray *flvBuffer_;
  // NSMutableArray *usedBlocks_;
}

@property (nonatomic, retain) NSString *rtmpUrl;
@property (nonatomic, assign) BOOL writeEnable;
@property (nonatomic, retain) NSMutableArray *flvBuffer;
@property (nonatomic, assign) NSInteger bufferSize;
@property (nonatomic, assign) BOOL writeQueueInUse;
// @property (nonatomic, retain) NSMutableArray *usedBlocks;

// - (void)disposeUsedBlocks;

@end

@implementation RtmpWrapper

@synthesize connected = connected_;
@synthesize rtmpUrl;
@synthesize writeEnable;
@synthesize maxBufferSizeInKbyte;
@synthesize bufferSize;

void rtmpLog(int level, const char *fmt, va_list args) {
  NSString *log = @"";
  switch (level) {
    default:
    case RTMP_LOGCRIT:
      log = @"FATAL";
      break;
    case RTMP_LOGERROR:
      log = @"ERROR";
      break;
    case RTMP_LOGWARNING:
      log = @"WARN";
      break;
    case RTMP_LOGINFO:
      log = @"INFO";
      break;
    case RTMP_LOGDEBUG:
      log = @"VERBOSE";
      break;
    case RTMP_LOGDEBUG2:
      log = @"DEBUG";
      break;
  }
    
  NSLog([log stringByAppendingString:[NSString
                                      stringWithUTF8String:fmt]],
        args);
}

- (id)init {
  self = [super init];
  if (self != nil) {
    connected_ = NO;
    flvBuffer_ = [[NSMutableArray alloc] init];
    // usedBlocks_ = [[NSMutableArray alloc] init];
    maxBufferSizeInKbyte = kMaxBufferSizeInKbyte;
    bufferSize = 0;
    writeQueueInUse_ = NO;
    
    signal(SIGPIPE, SIG_IGN);
    
    // Allocate rtmp context object
    rtmp_ = RTMP_Alloc();
    RTMP_LogSetLevel(RTMP_LOGALL);
    RTMP_LogCallback(rtmpLog);
  }
  return self;
}

- (void)dealloc {
  if (self.connected) {
    [self rtmpClose];
  }
  if (rtmpUrl) {
    [rtmpUrl release];
  }
  if (flvBuffer_) {
    [flvBuffer_ release];
  }
  /*
  [self disposeUsedBlocks];
  
  if (usedBlocks_) {
    [usedBlocks_ release];
  }
   */
  // Release rtmp context
  RTMP_Free(rtmp_);
  
  [super dealloc];
}

- (void)setLogInfo {
  RTMP_LogSetLevel(RTMP_LOGINFO);
}

- (BOOL)isConnected {
  if (rtmp_) {
    connected_ = RTMP_IsConnected(rtmp_);
  }
  return connected_;
}

- (void)rtmpClose {
  if (rtmp_) {
    RTMP_Close(rtmp_);
  }
}

- (BOOL)reconnect {
  if (!RTMP_IsConnected(rtmp_)) {
    if (!RTMP_Connect(rtmp_, NULL)) {
      return NO;
    }
  }
  return RTMP_ReconnectStream(rtmp_, 0);
}

+ (NSError *)errorRTMPFailedWithReason:(NSString *)errorReason
                               andCode:(RTMPErrorCode)errorCode {
  NSMutableDictionary *userinfo = [[NSMutableDictionary alloc] init];
  userinfo[NSLocalizedDescriptionKey] = errorReason;
  
  // create error object
  NSError *err = [NSError errorWithDomain:kErrorDomain
                                     code:errorCode
                                 userInfo:userinfo];
  [userinfo release];
  return err;
}

// Resize data buffer for the given data. If the buffer size is bigger than
// max size, remove first input and return error to the completion handler.
- (void)resizeBuffer:(NSData *)data {
  while (self.flvBuffer.count > 1 &&
         bufferSize + data.length > maxBufferSizeInKbyte * 1024) {
    NSDictionary *b = [self.flvBuffer objectAtIndex:0];
    bufferSize -= [[b objectForKey:@"length"] integerValue];
    WriteCompleteHandler handler = [b objectForKey:@"completion"];
   
    NSError *error =
      [RtmpWrapper errorRTMPFailedWithReason:@"RTMP buffer is full because "
                                              "either frequent send failing or"
                                              "some reason."
                                     andCode:RTMPErrorBufferFull];
    handler(-1, error);
    [self.flvBuffer removeObjectAtIndex:0];
  }
}

- (void)appendData:(NSData *)data
    withCompletion:(WriteCompleteHandler)completion {
  NSMutableDictionary *b = [[NSMutableDictionary alloc] init];
  [b setObject:data forKey:@"data"];
  [b setObject:[NSString stringWithFormat:@"%d", data.length] forKey:@"length"];
  [b setObject:completion forKey:@"completion"];
  
  bufferSize += data.length;

  @synchronized (self) {
    NSLog(@"item to write added (%u)", data.length);
    [self.flvBuffer addObject:b];
  }
  [b release];
}

- (void)write {
  NSMutableDictionary *item = nil;
  if (self.flvBuffer.count > 0) {
    self.writeQueueInUse = YES;
    item = [self.flvBuffer objectAtIndex:0];
  }
  
  if (item) {
    NSData *data = [item objectForKey:@"data"];
    int length = [[item objectForKey:@"length"] integerValue];
    WriteCompleteHandler handler = [item objectForKey:@"completion"];
    
    IFTimeoutBlock *block = [[IFTimeoutBlock alloc] init];
    IFTimeoutHandler timeoutBlock =^ {
      NSError *error =
      [RtmpWrapper errorRTMPFailedWithReason:@"Timed out for writing"
                                     andCode:RTMPErrorWriteTimeout];
      handler(-1, error);
    };
    
    IFExecutionBlock execution = ^{
      NSError *error = nil;
      NSUInteger sent = -1;
      @synchronized (self) {
        sent = [self rtmpWrite:data];
        if (sent != length) {
          error =
            [RtmpWrapper errorRTMPFailedWithReason:[NSString stringWithFormat:@"Failed to write data"]
                                           andCode:RTMPErrorWriteFail];
        }
      }
      
      [block signal];
      if (!block.timedOut) {
        handler(sent, error);
        if (error == nil) {
          [self.flvBuffer removeObject:item];
          bufferSize -= length;
          if (self.flvBuffer.count > 0) {
            [self write];
          } else {
            self.writeQueueInUse = NO;
          }
        }
        // If call fails or timed out, don't remove item and try again.
        // Let user decide whether reconnect or send it.
      }
      
      // [self.usedBlocks addObject:block];

    };
    
    // NSLog(@"execute write call in async (%u)", length);
    [block setExecuteAsyncWithTimeout:5
                          WithHandler:timeoutBlock
                    andExecutionBlock:execution];
    [block release];
  }
}

#pragma mark -
#pragma mark Async class Methods

- (void)rtmpOpenWithURL:(NSString *)url
            enableWrite:(BOOL)enableWrite
         withCompletion:(OpenCompleteHandler)handler {
  IFTimeoutBlock *block = [[IFTimeoutBlock alloc] init];
  IFTimeoutHandler timeoutBlock =^ {
    NSError *error =
    [RtmpWrapper errorRTMPFailedWithReason:
     [NSString stringWithFormat:@"Timed out for openning %@", url]
                                   andCode:RTMPErrorOpenTimeout];
    handler(error);
  };
  
  IFExecutionBlock execution = ^{
    NSError *error = nil;
    if (![self rtmpOpenWithURL:url enableWrite:enableWrite]) {
      error =
      [RtmpWrapper errorRTMPFailedWithReason:
       [NSString stringWithFormat:@"Cannot open %@", url]
                                     andCode:RTMPErrorURLOpenFail];
    }
    
    [block signal];
    if (!block.timedOut) {
      handler(error);
    }
    // [self.usedBlocks addObject:block];
      };
  
  [block setExecuteAsyncWithTimeout:3
                        WithHandler:timeoutBlock
                  andExecutionBlock:execution];
  [block release];

}

- (void)rtmpWrite:(NSData *)data
   withCompletion:(WriteCompleteHandler)completion {
  if (data) {
    [self appendData:data withCompletion:completion];
  }  
  
  if (!self.writeQueueInUse) {
    // Resize buffer for the given data.
    [self resizeBuffer:data];
    [self write];
  }
  
  // [self disposeUsedBlocks];
}
/*
- (void)disposeUsedBlocks {
  @synchronized (usedBlocks_) {
    for (IFTimeoutBlock *block in usedBlocks_) {
      [block release];
    }
    
    [usedBlocks_ removeAllObjects];
  }
}
*/

#pragma mark -
#pragma mark Sync class Methods

- (BOOL)rtmpOpenWithURL:(NSString *)url enableWrite:(BOOL)enableWrite {
  RTMP_Init(rtmp_);
  if (!RTMP_SetupURL(rtmp_,
                     (char *)[url cStringUsingEncoding:NSASCIIStringEncoding])) {
    return NO;
  }
  
  self.rtmpUrl = url;
  self.writeEnable = enableWrite;
  
  if (enableWrite) {
    RTMP_EnableWrite(rtmp_);
  }
  
  if (!RTMP_Connect(rtmp_, NULL) || !RTMP_ConnectStream(rtmp_, 0)) {
    return NO;
  }
  
  connected_ = RTMP_IsConnected(rtmp_);
  return YES;
}

- (NSUInteger)rtmpWrite:(NSData *)data {
  int sent = -1;
  if (self.connected) {
    sent = RTMP_Write(rtmp_, [data bytes], [data length]);
  }
  return sent;
}

#pragma mark -
#pragma mark Setters and Getters Methods

- (NSMutableArray *)flvBuffer {
  @synchronized (flvBuffer_) {
    return flvBuffer_;
  }
}

- (void)setFlvBuffer:(NSMutableArray *)b {
  @synchronized (flvBuffer_) {
    flvBuffer_ = b;
  }
}

- (BOOL)writeQueueInUse {
  @synchronized (self) {
    return writeQueueInUse_;
  }
}

- (void)setWriteQueueInUse:(BOOL)inUse {
  @synchronized (self) {
    writeQueueInUse_ = inUse;
  }
}

/*
- (NSMutableArray *)usedBlocks {
  @synchronized (usedBlocks_) {
    return usedBlocks_;
  }
}
*/

@end

