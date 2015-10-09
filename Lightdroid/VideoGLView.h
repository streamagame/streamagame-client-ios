//
//  VideoGLView.h
//  Lightdroid
//
//  Created by Justus Beyer on 07.10.15.
//  Copyright © 2015 Justus Beyer. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "libavformat/avformat.h"

@interface VideoGLView : UIView
- (instancetype)initWithFrame:(CGRect)frame andVideoSize:(CGSize)videoSize;
- (void)displayFrame:(AVFrame *) frame;

@end
