//
//  ViewController.h
//  Lightdroid
//
//  Created by Justus Beyer on 25.09.15.
//  Copyright © 2015 Justus Beyer. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "libavformat/avformat.h"
#import "libavcodec/avcodec.h"
#import "libavformat/avio.h"
#import "libswscale/swscale.h"

#import "CocoaAsyncSocket/AsyncUdpSocket.h"

@interface ViewController : UIViewController<AsyncUdpSocketDelegate> {

}

- (void)startPlayback;
- (void)stopPlayback;


@end

