//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@import AVFoundation;

#define DR_OK 0
#define DR_NEED_IDR -1

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView*)view;

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length;

- (CGSize)videoDimensions;
- (CGSize)videoPresentationDimensions;
- (CGRect)contentsRect;

@end
