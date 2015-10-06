//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import <VideoToolbox/VideoToolbox.h>
#import "libavutil/intreadwrite.h"

// #include "Limelight.h"

typedef struct tagH264_SLICE_INFO
{
    unsigned int   first_mb;
    unsigned short slice_type;
    unsigned short pic_parameter_set_id;
    unsigned int   frame_num;
} __attribute__((__packed__)) H264_SLICE_INFO;

@implementation VideoDecoderRenderer {
    UIView *_view;
    
    AVSampleBufferDisplayLayer* displayLayer;
    Boolean waitingForSps, waitingForPps;
    
    NSData *spsData, *ppsData;
    CMVideoFormatDescriptionRef formatDesc;
}

- (void)reinitializeDisplayLayer
{
    CALayer *oldLayer = displayLayer;
    
    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    displayLayer.bounds = _view.bounds;
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    displayLayer.position = CGPointMake(CGRectGetMidX(_view.bounds), CGRectGetMidY(_view.bounds));
    displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    
    CMTimebaseSetTime(displayLayer.controlTimebase, kCMTimeZero);
    CMTimebaseSetRate(displayLayer.controlTimebase, 1.0);

    
    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:displayLayer];
    }
    else {
        [_view.layer addSublayer:displayLayer];
    }
    
    // We need some parameter sets before we can properly start decoding frames
    waitingForSps = true;
    spsData = nil;
    waitingForPps = true;
    ppsData = nil;
    
    if (formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }
}

- (id)initWithView:(UIView*)view
{
    self = [super init];
    
    _view = view;
    
    [self reinitializeDisplayLayer];
    
    return self;
}

#define FRAME_START_PREFIX_SIZE 4
#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4
#define NAL_TYPE_SPS 0x7
#define NAL_TYPE_PPS 0x8

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(existingBuffer);
    
    unsigned char nalType = data[offset+NALU_START_PREFIX_SIZE] & 0x1F;
    // NSLog(@"NAL Type: %d", nalType);
    
    // If we're at index 1 (first NALU in frame), enqueue this buffer to the memory block
    // so it can handle freeing it when the block buffer is destroyed
    if (offset == 1) {
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        
        // Pass the real buffer pointer directly (no offset)
        // This will give it to the block buffer to free when it's released.
        // All further calls to CMBlockBufferAppendMemoryBlock will do so
        // at an offset and will not be asking the buffer to be freed.
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, data,
                                                nalLength + 1, // Add 1 for the offset we decremented
                                                kCFAllocatorDefault,
                                                NULL, 0, nalLength + 1, 0);
        if (status != noErr) {
            NSLog(@"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
        
        // Write the length prefix to existing buffer
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            NSLog(@"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
    } else {
        // Append a 4 byte buffer to this block for the length prefix
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, NULL,
                                                NAL_LENGTH_PREFIX_SIZE,
                                                kCFAllocatorDefault, NULL, 0,
                                                NAL_LENGTH_PREFIX_SIZE, 0);
        if (status != noErr) {
            NSLog(@"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
            return;
        }
        
        // Write the length prefix to the new buffer
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            NSLog(@"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
        
        // Attach the buffer by reference to the block buffer
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, &data[offset+NALU_START_PREFIX_SIZE],
                                                dataLength,
                                                kCFAllocatorNull, // Don't deallocate data on free
                                                NULL, 0, dataLength, 0);
        if (status != noErr) {
            NSLog(@"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
    }
}

// This function must free data
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length
{
    unsigned char nalType = data[FRAME_START_PREFIX_SIZE] & 0x1F;
    OSStatus status;
    
    // Check for previous decoder errors before doing anything
    if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"Display layer rendering failed: %@", displayLayer.error);
        
        // Recreate the display layer
        [self reinitializeDisplayLayer];
        
        // Request an IDR frame to initialize the new decoder
        return DR_NEED_IDR;
    }
    
    if (nalType == NAL_TYPE_SPS || nalType == NAL_TYPE_PPS) {
        if (nalType == NAL_TYPE_SPS && length >= 11) {
            NSLog(@"Got SPS");
            waitingForSps = false;
            
            // Preliminary assumption is that the received data contains only one NAL. We're going to confirm this ...
            int sps_size = length - FRAME_START_PREFIX_SIZE;
            
            // Search for another NAL in the data
            unsigned int offset = FRAME_START_PREFIX_SIZE;
            while (++offset < length - 4 && *(u_int32_t*)(data+offset) != 0x01000000);
            if (offset < length - 4) {
                sps_size = offset - FRAME_START_PREFIX_SIZE;
            }
            
            spsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:sps_size];
            // We got a new SPS so wait for a new PPS to match it
            waitingForPps = true;
            
            if (offset + FRAME_START_PREFIX_SIZE < length) {
                const unsigned int remaining_length = length - offset;
                unsigned char *copy = malloc(remaining_length);
                memcpy((void*)copy, data+offset, remaining_length);
                
                free(data);
                return [self submitDecodeBuffer:copy length:remaining_length];
            }

        } else if (nalType == NAL_TYPE_PPS) {
            NSLog(@"Got PPS");
            ppsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForPps = false;
        }
        
        // See if we've got all the parameter sets we need
        if (!waitingForSps && !waitingForPps && formatDesc == nil) {
            const uint8_t* const parameterSetPointers[] = { [spsData bytes], [ppsData bytes] };
            const size_t parameterSetSizes[] = { [spsData length], [ppsData length] };
            
            NSLog(@"Constructing new format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         2, /* count of parameter sets */
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                NSLog(@"Failed to create format description: %d", (int)status);
                formatDesc = NULL;
            }
        }
        
        // Free the data buffer
        free(data);
        
        // No frame data to submit for these NALUs
        return DR_OK;
    }
    
    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_OK;
    }
    
    /*if (nalType != 0x1 && nalType != 0x5) {
        // Don't submit parameter set data
        free(data);
        return DR_OK;
    }*/
    
    // Now we're decoding actual frame data here
    CMBlockBufferRef blockBuffer;
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &blockBuffer);
    if (status != noErr) {
        NSLog(@"CMBlockBufferCreateEmpty failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }
    
    int lastOffset = -1;
    for (int i = 0; i < length - FRAME_START_PREFIX_SIZE; i++) {
        // Search for a NALU
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            // It's the start of a new NALU
            if (lastOffset != -1) {
                
                // We've seen a start before this so enqueue that NALU
                [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:i - lastOffset];
            }
            
            lastOffset = i;
        }
    }
    
    if (lastOffset != -1) {
        // Enqueue the remaining data
        [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:length - lastOffset];
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    CMSampleBufferRef sampleBuffer;
    
    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  blockBuffer,
                                  true, NULL,
                                  NULL, formatDesc, 1, 0,
                                  NULL, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        NSLog(@"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(blockBuffer);
        return DR_NEED_IDR;
    }
    
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_EarlierDisplayTimesAllowed, kCFBooleanTrue);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanFalse/*kCFBooleanTrue*/);
    
    //NSLog(@"NAL Type: %d", nalType);
    
    if (nalType == 1) {
        // I-frame
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_PartialSync,kCFBooleanTrue);
        // CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanFalse/*kCFBooleanTrue*/);
    }
    else if (nalType == 5 || nalType == 6) {
        [displayLayer flush];
        // IDR ^= keyframe
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        // CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanTrue/*kCFBooleanTrue*/);
    }
    
    //dispatch_async(dispatch_get_main_queue(), ^{
 
    if (CMSampleBufferIsValid(sampleBuffer))
            [displayLayer enqueueSampleBuffer:sampleBuffer];
        else
            NSLog(@"Invalid sample buffer");
        
        if(displayLayer.error != nil) {
            NSLog(@"Error in display layer: %@", displayLayer.error);
        }
        
        if(displayLayer.status != AVQueuedSampleBufferRenderingStatusRendering)
            NSLog(@"DisplayLayer is not rendering.");
    
    [displayLayer setNeedsDisplay];
    
        // Dereference the buffers
        CFRelease(blockBuffer);
        CFRelease(sampleBuffer);
    //});
    
    return DR_OK;
}

- (CGSize)videoDimensions
{
    CGSize dimensions = {0, 0};
    
    if (formatDesc != nil) {
        CMVideoDimensions videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
        dimensions.height = videoDimensions.height;
        dimensions.width = videoDimensions.width;
    }
    
    return dimensions;
}

- (CGSize)videoPresentationDimensions
{
    CGSize dimensions = {0, 0};

    if (formatDesc)
        dimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDesc, true, true);
    
    return dimensions;
}

- (CGRect)contentsRect
{
    CGRect rect;
    if(displayLayer)
        rect = displayLayer.contentsRect;
    return rect;
}

@end
