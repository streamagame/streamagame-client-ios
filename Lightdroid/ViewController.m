//
//  ViewController.m
//  Lightdroid
//
//  Created by Justus Beyer on 25.09.15.
//  Copyright © 2015 Justus Beyer. All rights reserved.
//

#import "ViewController.h"
#import "VideoDecoderRenderer.h"

#import "VideoGLView.h"

#define	SDL_EVENT_MSGTYPE_NULL		0
#define	SDL_EVENT_MSGTYPE_KEYBOARD	1
#define	SDL_EVENT_MSGTYPE_MOUSEKEY	2
#define SDL_EVENT_MSGTYPE_MOUSEMOTION	3
#define SDL_EVENT_MSGTYPE_MOUSEWHEEL	4

// mouse event
#ifdef WIN32
#pragma pack(push, 1)
#endif
struct sdlmsg_mouse_s {
    unsigned short msgsize;
    unsigned char msgtype;		// SDL_EVENT_MSGTYPE_MOUSEKEY
    // SDL_EVENT_MSGTYPE_MOUSEMOTION
    // SDL_EVENT_MSGTYPE_MOUSEWHEEL
    unsigned char which;
    unsigned char is_pressed;	// for mouse button
    unsigned char mousebutton;	// mouse button
    unsigned char mousestate;	// mouse stat
    unsigned char relativeMouseMode;
    unsigned short mousex;
    unsigned short mousey;
    unsigned short mouseRelX;
    unsigned short mouseRelY;
}
#ifdef WIN32
#pragma pack(pop)
#else
__attribute__((__packed__))
#endif
;
typedef struct sdlmsg_mouse_s		sdlmsg_mouse_t;

@interface ViewController ()
@property (strong, nonatomic) AsyncUdpSocket *socket;
@property (atomic) BOOL stopPlaybackTrigger;
// @property (strong, atomic) VideoDecoderRenderer* renderer;
@property (strong, nonatomic) VideoGLView *videoGLView;
@end

@implementation ViewController {
    unsigned int msgCounter;
  	struct SwsContext *img_convert_ctx;
   	AVPicture picture;
    AVFormatContext *pFormatCtx;
    AVCodecContext *pCodecCtx;
    AVFrame *pFrame;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    msgCounter = 0;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // [self startPlayback];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

// Disable the status bar
- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)startPlayback {
    // Setup the H.264 hardware-renderer
    //self.renderer = [[VideoDecoderRenderer alloc] initWithView:self.view];
    
    // Connect to the RTSP live stream
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self displayRtspStream];
    });
    
    // Setup the UDP socket for sending input to the server
    self.socket = [[AsyncUdpSocket alloc] initWithDelegate:self];
}

- (void)stopPlayback {
    self.stopPlaybackTrigger = true;
    
//    self.renderer = nil;
    self.socket = nil;
}

- (void)displayRtspStream {
    AVCodec         *pCodec;
    
    av_log_set_level(AV_LOG_DEBUG);
    av_register_all();
    avformat_network_init();
    
    // Set the RTSP Options
    AVDictionary *opts = 0;
    if (/*usesTcp*/ false)
        av_dict_set(&opts, "rtsp_transport", "tcp", 0);

    pFormatCtx = avformat_alloc_context();
    if (!pFormatCtx) {
        av_log(NULL, AV_LOG_ERROR, "Couldn't create format context\n");
        return;
    }
    // pFormatCtx->flags = /*AVFMT_FLAG_NOFILLIN |*/ /*) AVFMT_FLAG_NOPARSE | AVFMT_FLAG_DISCARD_CORRUPT |*/ AVFMT_FLAG_IGNIDX | AVFMT_FLAG_IGNDTS | AVFMT_FLAG_GENPTS | AVFMT_FLAG_NOBUFFER |AVFMT_FLAG_FLUSH_PACKETS;
    // pFormatCtx->error_recognition = 0;
    pFormatCtx->flags = AVFMT_FLAG_NOBUFFER;
    
    // Demo stream: rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mov
    // rtsp://gl.justus.berlin:8554/desktop
    if (avformat_open_input(&pFormatCtx, [@"rtsp://gl.justus.berlin:8554/desktop" UTF8String], NULL, &opts) !=0 ) {
        av_log(NULL, AV_LOG_ERROR, "Couldn't open file\n");
        return;
    }
    
    // Retrieve stream information
    if (avformat_find_stream_info(pFormatCtx,NULL) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Couldn't find stream information\n");
        return;
    }
    
    // Find the first video stream
    int videoStream=-1;
    int audioStream=-1;
    
    for (int i=0; i<pFormatCtx->nb_streams; i++) {
        if (pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) {
            NSLog(@"found video stream");
            videoStream=i;
            break; // We skip audio.
        }
        
        if (pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_AUDIO) {
            audioStream=i;
            NSLog(@"found audio stream");
        }
    }
    
    if (videoStream==-1 /* && audioStream==-1*/) {
        return;
    }
    
    // Get a pointer to the codec context for the video stream
    pCodecCtx = pFormatCtx->streams[videoStream]->codec;
    pCodecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    pCodecCtx->flags2 |= AV_CODEC_FLAG2_FAST;
    
    // Find the decoder for the video stream
    pCodec = avcodec_find_decoder(pCodecCtx->codec_id);
    if (pCodec == NULL) {
        av_log(NULL, AV_LOG_ERROR, "Unsupported codec!\n");
        return;
    }
    
    // Open codec
    if (avcodec_open2(pCodecCtx, pCodec, NULL) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Cannot open video decoder\n");
        return;
    }
    
    // Allocate video frame
    pFrame = av_frame_alloc();
    
    AVPacket packet;
    self.stopPlaybackTrigger = false;
    
    bool is_first_packet = true;
    
    av_read_play(pFormatCtx);
    
    CGSize screenDimensions = [[UIScreen mainScreen] bounds].size;
    while (!self.stopPlaybackTrigger && av_read_frame(pFormatCtx, &packet) >=0 ) {
        // Is this a packet from the video stream?
        if(packet.stream_index==videoStream) {
            // NSLog(@"Video data received.");
            
            int frame_finished = 0;
            avcodec_decode_video2(pCodecCtx, pFrame, &frame_finished, &packet);

            if(is_first_packet) {
                // Copy and submit SPS and PPS data to the decoder first.
                unsigned char *sps_pps_data = malloc(pFormatCtx->streams[videoStream]->codec->extradata_size);
                unsigned int sps_pps_data_length = pFormatCtx->streams[videoStream]->codec->extradata_size;
//                memcpy(sps_pps_data, pFormatCtx->streams[videoStream]->codec->extradata, sps_pps_data_length);
  //              [self.renderer submitDecodeBuffer:sps_pps_data length:sps_pps_data_length];
                
                // Allocate RGB picture
                avpicture_alloc(&picture, PIX_FMT_RGB24, screenDimensions.width, screenDimensions.height);
                
                // Setup scaler
                /*static int sws_flags =  SWS_FAST_BILINEAR;
                img_convert_ctx = sws_getContext(pCodecCtx->width,
                                                 pCodecCtx->height,
                                                 pCodecCtx->pix_fmt,
                                                 screenDimensions.width,
                                                 screenDimensions.height,
                                                 PIX_FMT_RGB24,
                                                 sws_flags, NULL, NULL, NULL);*/
                CGSize videoSize = CGSizeMake(pCodecCtx->width, pCodecCtx->height);
                dispatch_sync(dispatch_get_main_queue(), ^{
                    self.videoGLView = [[VideoGLView alloc] initWithFrame:self.view.frame andVideoSize:videoSize];
                    assert(self.videoGLView != nil);
                    [self.view addSubview:self.videoGLView];
                });

                
                is_first_packet = false;
            }
            
/*            unsigned char* duplicated_data = malloc(packet.size);
            memcpy(duplicated_data, packet.data, packet.size);
            [self.renderer submitDecodeBuffer:duplicated_data length:packet.size];*/
            
            if (frame_finished && pFrame && pFrame->data[0] && self.videoGLView) {
                /*sws_scale(img_convert_ctx,
                          pFrame->data,
                          pFrame->linesize,
                          0,
                          pCodecCtx->height,
                          picture.data,
                          picture.linesize);
                
                CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
                CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, picture.data[0], picture.linesize[0]*screenDimensions.height,kCFAllocatorNull);
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGImageRef cgImage = CGImageCreate(screenDimensions.width,
                                                   screenDimensions.height,
                                                   8,
                                                   24,
                                                   picture.linesize[0],
                                                   colorSpace,
                                                   bitmapInfo,
                                                   provider, 
                                                   NULL, 
                                                   NO, 
                                                   kCGRenderingIntentDefault);
                CGColorSpaceRelease(colorSpace);
                
                dispatch_sync(dispatch_get_main_queue(), ^{
                    self.imageView.image = [UIImage imageWithCGImage:cgImage];
                });
                
                CGImageRelease(cgImage);
                CGDataProviderRelease(provider);
                CFRelease(data);*/
                
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self.videoGLView displayFrame:pFrame];
                });
            }
        } /*else if (packet.stream_index != audioStream) {
            // NSLog(@"Received packet in stream %d", packet.stream_index);
        }*/
        
        av_free_packet(&packet);
    }
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self.videoGLView removeFromSuperview];
        self.videoGLView = nil;
    });
    
    av_read_pause(pFormatCtx);
    pFormatCtx->streams[videoStream]->discard = AVDISCARD_ALL;
    avformat_close_input(&pFormatCtx);
    avformat_free_context(pFormatCtx);
    pFormatCtx = nil;
    
  	avpicture_free(&picture);
   	sws_freeContext(img_convert_ctx);
    
    NSLog(@"Playback stopped.");
    return;
    
initError:
    NSLog(@"Bad things happened");
}

#pragma mark - Touch handling

- (CGRect)computeVideoRect
{
    CGRect videoRect;
    
    // Get the video dimensions and compute aspect ratio
    CGSize videoDimensions = (pCodecCtx) ? CGSizeMake(pCodecCtx->width, pCodecCtx->height) : CGSizeMake(1, 1);

    if (videoDimensions.height == 0 || videoDimensions.width == 0) return videoRect; // ^= shit + fan... you know
    float videoAspectRatio = videoDimensions.width / videoDimensions.height;
    
    // Get the view's dimensions and compute its aspect ratio
    CGSize screenDimensions = [[UIScreen mainScreen] bounds].size;
    float screenAspectRatio = screenDimensions.width / screenDimensions.height;
    
    // Lets do the math and make some educated guess where the video is displayed on the screen.
    
    if (videoAspectRatio < screenAspectRatio) {
        // Video is thinner than the screen.
        videoRect.size.height = screenDimensions.height;
        videoRect.origin.y = 0;
        
        videoRect.size.width = screenDimensions.height * videoAspectRatio;
        videoRect.origin.x = (screenDimensions.width - videoRect.size.width) / 2.0;
    }
    else {
        // Video is wider than the screen (or exactly the same)
        videoRect.size.width = screenDimensions.width;
        videoRect.origin.x = 0;
        
        videoRect.size.height = screenDimensions.width / videoAspectRatio;
        videoRect.origin.y = (screenDimensions.height - videoRect.size.height) / 2.0;
    }
    
    return videoRect;
}

- (CGPoint)convertToRelativePoint:(CGPoint)absolutePoint
{
    // This method assumes that the video is displayed in a full-screen while maintaining aspect ratio manner.
    CGPoint relativePoint;
    CGRect videoRect = [self computeVideoRect];
    if (videoRect.size.height == 0 || videoRect.size.width == 0) return relativePoint;
    
    // Compute relative position components
    
    if (absolutePoint.x < videoRect.origin.x)
        relativePoint.x = 0;
    else if (absolutePoint.x >= videoRect.origin.x + videoRect.size.width)
        relativePoint.x = 1;
    else
        relativePoint.x = (absolutePoint.x - videoRect.origin.x) / videoRect.size.width;
    
    if (absolutePoint.y < videoRect.origin.y)
        relativePoint.y = 0;
    else if (absolutePoint.y >= videoRect.origin.y + videoRect.size.height)
        relativePoint.y = 1;
    else
        relativePoint.y = (absolutePoint.y - videoRect.origin.y) / videoRect.size.height;
    
    return relativePoint;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self sendTouchMessage:touches withEvent:event stillTouched:false currentlyMoving:true];
    [self sendTouchMessage:touches withEvent:event stillTouched:true currentlyMoving:false];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self sendTouchMessage:touches withEvent:event stillTouched:false currentlyMoving:false];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self sendTouchMessage:touches withEvent:event stillTouched:false currentlyMoving:false];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self sendTouchMessage:touches withEvent:event stillTouched:true currentlyMoving:true];
}

#pragma mark - Input transmission

- (void)sendTouchMessage:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event stillTouched:(bool)clicked currentlyMoving:(bool)moving
{
    CGPoint absolutePoint = [[[event allTouches] anyObject] locationInView:self.view];
    CGPoint relativePoint = [self convertToRelativePoint:absolutePoint];
    CGSize videoDimension = (pCodecCtx) ? CGSizeMake(pCodecCtx->width, pCodecCtx->height) : CGSizeMake(1, 1);
    //NSLog(@"Touch down: %f x %f", absolutePoint.x, absolutePoint.y);
    
    unsigned short mousex = relativePoint.x * videoDimension.width;
    unsigned short mousey = relativePoint.y * videoDimension.height;
    
    //NSLog(@"Sending mouse %d x %d", mousex, mousey);
    
    // Prepare message
    sdlmsg_mouse_t msg;
    bzero(&msg, sizeof(sdlmsg_mouse_t));
    msg.msgsize = htons(sizeof(sdlmsg_mouse_t));
    msg.msgtype = (moving) ? SDL_EVENT_MSGTYPE_MOUSEMOTION : SDL_EVENT_MSGTYPE_MOUSEKEY;
    msg.is_pressed = (clicked) ? 1 : 0; //1 heisst pressed
    msg.mousebutton = 1; //1 heisst SDL_BUTTON_LEFT
    // msg.mousex = htons(relativePoint.x * videoRect.size.width * 2 /* cuz retina */);
    // msg.mousey = htons(relativePoint.y * videoRect.size.height * 2 /* cuz retina */);
    msg.mousex = htons(mousex);
    msg.mousey = htons(mousey);
    msg.mouseRelX = htons(0);
    msg.mouseRelY = htons(0);
    
    NSData *data = [NSData dataWithBytes:&msg length:sizeof(sdlmsg_mouse_t)];
    [self.socket sendData:data toHost:@"gl.justus.berlin" port:8555 withTimeout:-1 tag:msgCounter++];
}
@end
