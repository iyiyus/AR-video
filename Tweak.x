#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
// #import "util.h"

static NSFileManager *g_fileManager = nil; // 文件管理对象
static UIPasteboard *g_pasteboard = nil; // 剪贴板对象
static BOOL g_canReleaseBuffer = YES; // 当前是否可以释放buffer
static BOOL g_bufferReload = YES; // 是否需要立即重新刷新视频文件
static AVSampleBufferDisplayLayer *g_previewLayer = nil; // 原生相机预览
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // 如果存在 VideoDataOutput, 预览画面会同步VideoDataOutput的画面, 如果没有则会直接读取视频显示
static BOOL g_cameraRunning = NO;
static NSString *g_cameraPosition = @"B"; // B 为后置摄像头、F 为前置摄像头
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // 视频的方向

NSString *g_isMirroredMark = nil; // 镜像翻转标记，在 %ctor 中初始化为进程可写的 Caches 路径
NSString *g_tempFile = nil; // 临时文件位置，在 %ctor 中初始化为进程可写的 Caches 路径

// 前置声明（供 QQ 视频通话适配使用）
void ui_selectVideo(void);
void qq_continuePendingCall(void);


@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef) originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
@end

@implementation GetFrame
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable) originSampleBuffer :(BOOL)forceReNew{
    static AVAssetReader *reader = nil;
    // static AVAssetReaderTrackOutput *trackout = nil;
    static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
    static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
    static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
    // static AVAssetReaderTrackOutput *audioTrackout_pcm = nil;

    static CMSampleBufferRef sampleBuffer = nil;

    // origin buffer info
    CMFormatDescriptionRef formatDescription = nil;
    CMMediaType mediaType = -1;
    CMMediaType subMediaType = -1;
    CMVideoDimensions dimensions;
    if (originSampleBuffer != nil) {
        formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
        mediaType = CMFormatDescriptionGetMediaType(formatDescription);
        subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        if (mediaType != kCMMediaType_Video) {
            // if (mediaType == kCMMediaType_Audio && subMediaType == kAudioFormatLinearPCM) {
            //     if (reader != nil && audioTrackout_pcm != nil && [reader status] == AVAssetReaderStatusReading) {
            //         NSLog(@"ok");
                    
            //         static CMSampleBufferRef audioBuffer = nil;
            //         if (audioBuffer != nil) CFRelease(audioBuffer);
            //         audioBuffer = [audioTrackout_pcm copyNextSampleBuffer];
            //         NSLog(@"audioBuffer = %@", audioBuffer);
            //         // return audioBuffer;
            //     }
            // }
            // @see https://developer.apple.com/documentation/coremedia/cmmediatype?language=objc
            return originSampleBuffer;
        }
    }

    // 没有替换视频则返回空以使用原来的数据
    if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
    if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) return sampleBuffer; // 不能释放buffer时返回上一个buffer


    static NSTimeInterval renewTime = 0;
    // 选择了新的替换视频
    if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - renewTime > 3) {
            renewTime = nowTime;
            g_bufferReload = YES;
        }
    }

    if (g_bufferReload) {
        g_bufferReload = NO;
        @try{
            // AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:downloadFilePath]];
            AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject]; // 获取轨道
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  : YUV420 用于标清视频[420v]
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   : YUV422 用于高清视频[420f] 
            // kCVPixelFormatType_32BGRA : 输出的是BGRA的格式，适用于OpenGL和CoreImage

            // OSType type = kCVPixelFormatType_32BGRA;
            // NSDictionary *readerOutputSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(type)}; // 将视频帧解压缩为 32 位 BGRA 格式
            // trackout = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:readerOutputSettings];

            videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
            videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
            
            // AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject]; // 获取轨道
            // audioTrackout_pcm = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatLinearPCM]}];
            
            
            [reader addOutput:videoTrackout_32BGRA];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarVideoRange];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarFullRange];

            // [reader addOutput:audioTrackout_pcm];

            [reader startReading];
            // NSLog(@"这是初始化读取");
        }@catch(NSException *except) {
            NSLog(@"初始化读取视频出错:%@", except);
        }
    }
    // NSLog(@"刷新了");

    CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];

    CMSampleBufferRef newsampleBuffer = nil;
    // 根据subMediaTyp拷贝对应的类型
    switch(subMediaType) {
        case kCVPixelFormatType_32BGRA:
            // NSLog(@"--->kCVPixelFormatType_32BGRA");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            // NSLog(@"--->kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            // NSLog(@"--->kCVPixelFormatType_420YpCbCr8BiPlanarFullRange");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
            break;
        default:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
    }
    // 释放内存
    if (videoTrackout_32BGRA_Buffer != nil) CFRelease(videoTrackout_32BGRA_Buffer);
    if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer != nil) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
    if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer != nil) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);

    if (newsampleBuffer == nil) {
        g_bufferReload = YES;
    }else {
        if (sampleBuffer != nil) CFRelease(sampleBuffer);
        if (originSampleBuffer != nil) {

            // NSLog(@"---->%@", originSampleBuffer);
            // NSLog(@"====>%@", formatDescription);

            CMSampleBufferRef copyBuffer = nil;
            
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);

            // NSLog(@"width:%ld height:%ld", CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
            // NSLog(@"width:%d height:%d ===", dimensions.width, dimensions.height);

            // TODO:: 滤镜

            CMSampleTimingInfo sampleTime = {
                .duration = CMSampleBufferGetDuration(originSampleBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
            };

            CMVideoFormatDescriptionRef videoInfo = nil;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
            
            // 如果传了这个buffer则需要按照这个buffer去生成
            // CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer, [[NSDate date] timeIntervalSince1970] * 1000);

            // CVImage Buffer
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
            // NSLog(@"cvimagebuffer ->%@", copyBuffer);

            if (copyBuffer != nil) {
                CFDictionaryRef exifAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                CFDictionaryRef TIFFAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);

                // 设定EXIF信息
                if (exifAttachments != nil) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exifAttachments, kCMAttachmentMode_ShouldPropagate);
                // 设定TIFF信息
                if (exifAttachments != nil) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", TIFFAttachments, kCMAttachmentMode_ShouldPropagate);
                
                // NSLog(@"设置了exit信息 %@", CMGetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", NULL));
                sampleBuffer = copyBuffer;
                // NSLog(@"--->GetDataBuffer = %@", CMSampleBufferGetDataBuffer(copyBuffer));
            }
            CFRelease(newsampleBuffer);
            // sampleBuffer = newsampleBuffer;
        }else {
            // 直接从视频读取的 kCVPixelFormatType_32BGRA 
            sampleBuffer = newsampleBuffer;
        }
    }
    if (CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
    return nil;
}
+(UIWindow*)getKeyWindow{
    // need using [GetFrame getKeyWindow].rootViewController
    UIWindow *keyWindow = nil;
    if (keyWindow == nil) {
        NSArray *windows = UIApplication.sharedApplication.windows;
        for(UIWindow *window in windows){
            if(window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
    }
    return keyWindow;
}
@end


CALayer *g_maskLayer = nil;
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    %orig;
    // self.opacity = 0;
    // self.borderColor = [UIColor blackColor].CGColor;

    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }

    // 播放条目
    if (![[self sublayers] containsObject:g_previewLayer]) {
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // black mask
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];

        // layer size init
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
        });
        // NSLog(@"添加了 %@", [self sublayers]);
    }
}
%new
-(void)step:(CADisplayLink *)sender{
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        if (g_maskLayer != nil) g_maskLayer.opacity = 1;
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 1;
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
    }else {
        if (g_maskLayer != nil) g_maskLayer.opacity = 0;
        if (g_previewLayer != nil) g_previewLayer.opacity = 0;
    }

    if (g_cameraRunning && g_previewLayer != nil) {
        // NSLog(@"g_previewLayer=>%@", g_previewLayer);
        // NSLog(@"g_previewLayer.readyForMoreMediaData %@", g_previewLayer.readyForMoreMediaData?@"yes":@"no");
        g_previewLayer.frame = self.bounds;
        // NSLog(@"-->%@", NSStringFromCGSize(g_previewLayer.frame.size));

        switch(g_photoOrientation) {
            case AVCaptureVideoOrientationPortrait:
                // NSLog(@"AVCaptureVideoOrientationPortrait");
            case AVCaptureVideoOrientationPortraitUpsideDown:
                // NSLog(@"AVCaptureVideoOrientationPortraitUpsideDown");
                g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0);break;
            case AVCaptureVideoOrientationLandscapeRight:
                // NSLog(@"AVCaptureVideoOrientationLandscapeRight");
                g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0);break;
            case AVCaptureVideoOrientationLandscapeLeft:
                // NSLog(@"AVCaptureVideoOrientationLandscapeLeft");
                g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0);break;
            default:
                g_previewLayer.transform = self.transform;
        }

        // 防止和VideoOutput冲突
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            // 帧率控制
            static CMSampleBufferRef copyBuffer = nil;
            if (nowTime - refreshTime > 1000 / 33 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                g_photoOrientation = -1;
                // NSLog(@"-==-·刷新了 %f", nowTime);
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
                if (newBuffer != nil) {
                    [g_previewLayer flush];
                    if (copyBuffer != nil) CFRelease(copyBuffer);
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer != nil) [g_previewLayer enqueueSampleBuffer:copyBuffer];

                    // camera info
                    NSDate *datenow = [NSDate date];
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                    CGSize dimensions = self.bounds.size;
                    NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%.0f  H:%.0f",
                        [formatter stringFromDate:datenow],
                        [NSProcessInfo processInfo].processName,
                        [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, @"preview"],
                        dimensions.width, dimensions.height
                    ];
                    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                    [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
                }
            }
        }
    }
}
%end


%hook AVCaptureSession
-(void) startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
	NSLog(@"开始使用摄像头了， 预设值是 %@", [self sessionPreset]);
	%orig;
}
-(void) stopRunning {
    g_cameraRunning = NO;
	NSLog(@"停止使用摄像头了");
	%orig;
}
- (void)addInput:(AVCaptureDeviceInput *)input {
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
    }
 	// NSLog(@"添加了一个输入设备 %@", [[input device] activeFormat]);
	%orig;
}
- (void)addOutput:(AVCaptureOutput *)output{
	NSLog(@"添加了一个输出设备 %@", output);
	%orig;
}
%end


%hook AVCaptureStillImageOutput
- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler{
    g_canReleaseBuffer = NO;
    NSLog(@"拍照了 %@", handler);
    void (^newHandler)(CMSampleBufferRef imageDataSampleBuffer, NSError *error) = ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        NSLog(@"拍照调用 %@", handler);
        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:imageDataSampleBuffer :YES];
        if (newBuffer != nil) {
            imageDataSampleBuffer = newBuffer;
        }
        handler(imageDataSampleBuffer, error);
        g_canReleaseBuffer = YES;
    };
    %orig(connection, [newHandler copy]);
}
// TODO:: block buffer 尚未完成所以需要这里
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer{
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);

        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        if (@available(iOS 11.0, *)) { // 旋转问题
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];break;
                case AVCaptureVideoOrientationLandscapeRight:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
        return theNewPhoto;
    }
    return %orig;
}
%end

%hook AVCapturePhotoOutput
// TODO:: block buffer 尚未完成所以需要这里
+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer{
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        if (@available(iOS 11.0, *)) { // 旋转问题
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];break;
                case AVCaptureVideoOrientationLandscapeRight:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
        return theNewPhoto;
    }
    return %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate{
    if (settings == nil || delegate == nil) return %orig;
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    NSString *className = NSStringFromClass([delegate class]);
    if ([hooked containsObject:className] == NO) {
        [hooked addObject:className];

        if (@available(iOS 10.0, *)) {
            __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *output, CMSampleBufferRef photoSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *output, CMSampleBufferRef photoSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error){
                    g_canReleaseBuffer = NO;
                    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:photoSampleBuffer :NO];
                    if (newBuffer != nil) {
                        photoSampleBuffer = newBuffer;
                        // NSLog(@"新的buffer = %@", newBuffer);
                        // NSLog(@"旧的buffer = %@", photoSampleBuffer);
                        // NSLog(@"旧的previewPhotoSampleBuffer = %@", previewPhotoSampleBuffer);
                    }
                    NSLog(@"captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
                    // photoSampleBuffer = newPhotoBuffer;
                    // previewPhotoSampleBuffer = newPhotoBuffer;
                    @try{
                        original_method(self, @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:), output, photoSampleBuffer, previewPhotoSampleBuffer, resolvedSettings, bracketSettings, error);
                        g_canReleaseBuffer = YES;
                    }@catch(NSException *except) {
                        NSLog(@"出错了 %@", except);
                    }
                }), (IMP*)&original_method
            );
            __block void (*original_method2)(id self, SEL _cmd, AVCapturePhotoOutput *output, CMSampleBufferRef rawSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingRawPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *output, CMSampleBufferRef rawSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error){
                    NSLog(@"---raw->captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
                    // rawSampleBuffer = newPhotoBuffer;
                    // previewPhotoSampleBuffer = newPhotoBuffer;
                    return original_method2(self, @selector(captureOutput:didFinishProcessingRawPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:), output, rawSampleBuffer, previewPhotoSampleBuffer, resolvedSettings, bracketSettings, error);
                }), (IMP*)&original_method2
            );
        }

        if (@available(iOS 11.0, *)){ // iOS 11 之后
            __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error){
                    if (![g_fileManager fileExistsAtPath:g_tempFile]) {
                        return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                    }

                    g_canReleaseBuffer = NO;
                    static CMSampleBufferRef copyBuffer = nil;

                    // 这里没有buffer，临时创建一个
                    // NSLog(@"photo.pixelBuffer= %@", photo.pixelBuffer);
                    CMSampleBufferRef tempBuffer = nil;
                    CVPixelBufferRef tempPixelBuffer = photo.pixelBuffer;
                    CMSampleTimingInfo sampleTime = {0,};
                    CMVideoFormatDescriptionRef videoInfo = nil;
                    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, &videoInfo);
                    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &tempBuffer);

                    // 新的数据
                    NSLog(@"tempbuffer = %@, photo.pixelBuffer = %@, photo.CGImageRepresentation=%@", tempBuffer, photo.pixelBuffer, photo.CGImageRepresentation);
                    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:tempBuffer :YES];
                    if (tempBuffer != nil) CFRelease(tempBuffer); // 释放这个临时buffer

                    if (newBuffer != nil) { // 如果存在新的替换数据则挂钩属性
                        if (copyBuffer != nil) CFRelease(copyBuffer);
                        CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);

                        __block CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(copyBuffer);
                        CIImage *ciimage = [CIImage imageWithCVImageBuffer:imageBuffer];

                        CIImage *ciimageRotate = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                        CIContext *cicontext = [CIContext new]; // 此处旋转问题
                        __block CGImageRef _Nullable cgimage = [cicontext createCGImage:ciimageRotate fromRect:ciimageRotate.extent];

                        UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                        __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);

                        // 获取到了新的buffer之后开始挂钩属性
                        __block NSData *(*fileDataRepresentationWithCustomizer)(id self, SEL _cmd, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer);
                        MSHookMessageEx(
                            [photo class], @selector(fileDataRepresentationWithCustomizer:),
                            imp_implementationWithBlock(^(id self, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer){
                                NSLog(@"fileDataRepresentationWithCustomizer");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentationWithCustomizer(self, @selector(fileDataRepresentationWithCustomizer:), customizer);
                            }), (IMP*)&fileDataRepresentationWithCustomizer
                        );

                        __block NSData *(*fileDataRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(fileDataRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                NSLog(@"fileDataRepresentation");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentation(self, @selector(fileDataRepresentation));
                            }), (IMP*)&fileDataRepresentation
                        );

                        __block CVPixelBufferRef *(*previewPixelBuffer)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(previewPixelBuffer),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                NSLog(@"previewPixelBuffer");
                                // RotatePixelBufferToAngle(imageBuffer, radians(-90));
                                return nil;
                            }), (IMP*)&previewPixelBuffer
                        );

                        __block CVImageBufferRef (*pixelBuffer)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(pixelBuffer),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                NSLog(@"pixelBuffer");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return imageBuffer;
                                return pixelBuffer(self, @selector(pixelBuffer));
                            }), (IMP*)&pixelBuffer
                        );

                        __block CGImageRef _Nullable(*CGImageRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(CGImageRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                NSLog(@"CGImageRepresentation");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return CGImageRepresentation(self, @selector(CGImageRepresentation));
                            }), (IMP*)&CGImageRepresentation
                        );

                        __block CGImageRef _Nullable(*previewCGImageRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(previewCGImageRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                NSLog(@"previewCGImageRepresentation");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return previewCGImageRepresentation(self, @selector(previewCGImageRepresentation));
                            }), (IMP*)&previewCGImageRepresentation
                        );
                    }
                    g_canReleaseBuffer = YES;
                    
                    // NSLog(@"原生拍照了 previewPixelBuffer = %@", photo.previewPixelBuffer );
                    // NSLog(@"原生拍照了 fileDataRepresentatio = %@", [photo fileDataRepresentation]);

                    return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                }), (IMP*)&original_method
            );
        }
    }
    
    NSLog(@"capturePhotoWithSettings--->[%@]   [%@]", settings, delegate);
    %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    // NSLog(@"sampleBufferDelegate--->%@", [sampleBufferDelegate class]); // TODO:: 同一个软件可能会有不同的代理对象，需要每个对象替换一次
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) return %orig;
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    if ([hooked containsObject:className] == NO) {
        [hooked addObject:className];
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;
        // NSLog(@"准备hook-->%@ %p", [sampleBufferDelegate class], original_method);

        // NSLog(@"---------> AVCaptureVideoDataOutput -> videoSettings = %@", [self videoSettings]);
        // 先动态hook然后调用原始方法使用这个queue
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // NSLog(@"求求你了，出现吧! 【self = %@】 params = %p", self, original_method);
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;

                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];

                // 用buffer来刷新预览
                NSString *previewType = @"buffer";
                g_photoOrientation = [connection videoOrientation];
                if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                    previewType = @"buffer - preview";
                }

                static NSTimeInterval oldTime = 0;
                NSTimeInterval nowTime = g_refreshPreviewByVideoDataOutputTime;
                if (nowTime - oldTime > 3000) { // 3秒钟刷新一次
                    oldTime = nowTime;
                    // camera info
                    // NSLog(@"set camera info");
                    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
                    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                    NSDate *datenow = [NSDate date];
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                    NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%d  H:%d",
                        [formatter stringFromDate:datenow],
                        [NSProcessInfo processInfo].processName,
                        [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, previewType],
                        dimensions.width, dimensions.height
                    ];
                    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                    [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
                }
                
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer != nil? newBuffer: sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
	// NSLog(@"AVCaptureVideoDataOutput -> setSampleBufferDelegate [%@] [%@]", sampleBufferDelegate, sampleBufferCallbackQueue);
	%orig;
}
%end

// 元数据
// %hook AVCaptureMetadataOutput
// - (void)setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)objectsDelegate queue:(dispatch_queue_t)objectsCallbackQueue{
//     if (objectsDelegate == nil || objectsCallbackQueue == nil) {
//         NSLog(@"咋是空的啊 AVCaptureMetadataOutput");
//         return %orig;
//     }
//     static void *(*original_method)(id self, SEL _cmd, AVCaptureOutput *output, NSArray<__kindof AVMetadataObject *> *metadataObjects, AVCaptureConnection *connection) = NULL;
//     if (original_method == NULL) {
//         NSLog(@"挂钩setMetadataObjectsDelegate");
//         MSHookMessageEx(
//             [objectsDelegate class], @selector(captureOutput:didOutputMetadataObjects:fromConnection:),
//             imp_implementationWithBlock(^(id self, AVCaptureOutput *output, NSArray<__kindof AVMetadataObject *> *metadataObjects, AVCaptureConnection *connection){
//                 // NSLog(@"捕获到元数据 %@", metadataObjects);

//                 original_method(self, @selector(captureOutput:didOutputMetadataObjects:fromConnection:), output, metadataObjects, connection);
//             }), (IMP*)&original_method
//         );
//     }
// 	NSLog(@"AVCaptureMetadataOutput -> setMetadataObjectsDelegate [%@]   [%@]", objectsDelegate, objectsCallbackQueue);
// 	%orig;
// }
// %end


// UI
@interface CCUIImagePickerDelegate : NSObject <UINavigationControllerDelegate,UIImagePickerControllerDelegate>
@end
@implementation CCUIImagePickerDelegate
// 选择图片成功调用此方法
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    [[GetFrame getKeyWindow].rootViewController dismissViewControllerAnimated:YES completion:nil];
    NSLog(@"%@", info);
    // NSString *result = @"应用失败!";
    // 选择的图片信息存储于info字典中
    NSString *selectFile = info[@"UIImagePickerControllerMediaURL"];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];

    if ([g_fileManager copyItemAtPath:selectFile toPath:g_tempFile error:nil]) {
        [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
        // result = @"应用成功!";
        sleep(1);
        [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];  
        // QQ 视频通话适配：替换视频已就位，继续执行被暂存的视频电话拨号
        qq_continuePendingCall();
    }
    // UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"VCAM" message:result preferredStyle:UIAlertControllerStyleAlert];
    // UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"oj8k" style:UIAlertActionStyleDefault handler:nil];
    // [alertController addAction:cancel];
    // [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];

}
// 取消图片选择调用此方法
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [[GetFrame getKeyWindow].rootViewController dismissViewControllerAnimated:YES completion:nil];
    // selectFile = nil;
}
@end


// UI
static UIAlertController *g_currentMenu = nil; // 当前显示的完整模式菜单（三指长按开/关）
static NSString *g_downloadAddress = @""; // 下载地址
static BOOL g_downloadRunning = NO; // 是否正在下载中

void ui_selectVideo(void){
    static CCUIImagePickerDelegate *delegate = nil;
    if (delegate == nil) delegate = [CCUIImagePickerDelegate new];
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = [NSArray arrayWithObjects:@"public.movie",/* @"public.image",*/ nil];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    if (@available(iOS 11.0, *)) picker.videoExportPreset = AVAssetExportPresetPassthrough;
    picker.allowsEditing = YES;
    picker.delegate = delegate;
    [[GetFrame getKeyWindow].rootViewController presentViewController:picker animated:YES completion:nil];
}

@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)getVolume:(float*)arg1 forCategory:(id)arg2;
- (BOOL)setVolumeTo:(float)arg1 forCategory:(id)arg2;
@end

/**
 * 下载视频
 * @param bool quick 是否为便捷下载，这种情况下尽量减少弹窗
 */
void ui_downloadVideo(){
    if (g_downloadRunning) return;

    void (^startDownload)(void) = ^{
        g_downloadRunning = YES;
        
        NSString *tempPath = [NSString stringWithFormat:@"%@.downloading.mov", g_tempFile];

        NSData *urlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:g_downloadAddress]];
        if ([urlData writeToFile:tempPath atomically:YES]) {
            AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", tempPath]]];
            if (asset.playable) {
                // 文件下载完成
                if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
                [g_fileManager moveItemAtPath:tempPath toPath:g_tempFile error:nil];
                [[%c(AVSystemController) sharedAVSystemController] setVolumeTo:0 forCategory:@"Ringtone"];
                // 标识视频有变动
                [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
                sleep(1);
                [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
            }else {
                if ([g_fileManager fileExistsAtPath:tempPath]) [g_fileManager removeItemAtPath:tempPath error:nil];
            }
        }else {
            if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
        }
        [[%c(AVSystemController) sharedAVSystemController] setVolumeTo:0 forCategory:@"Ringtone"];
        g_downloadRunning = NO;
    };
    dispatch_async(dispatch_queue_create("download", nil), startDownload);
}

// 显示完整模式菜单（三指长按打开）
void ui_showMenu(){
    // 剪贴板上的分辨率信息
    NSString *str = g_pasteboard.string;
    NSString *infoStr = @"使用镜头后将记录信息";
    if (str != nil && [str hasPrefix:@"CCVCAM"]) {
        str = [str substringFromIndex:6]; // 去掉前缀
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:str options:0];
        NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        infoStr = decodedString;
    }

    // 提示视频质量
    NSString *title = @"iOS-VCAM";
    if ([g_fileManager fileExistsAtPath:g_tempFile]) title = @"iOS-VCAM ✅";
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:infoStr preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *next = [UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        ui_selectVideo();
    }];
    UIAlertAction *download = [UIAlertAction actionWithTitle:@"下载视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        // 设置下载地址
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"下载视频" message:@"尽量使用MOV格式视频\nMP4也可, 其他类型尚未测试" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            if ([g_downloadAddress isEqual:@""]) {
                textField.placeholder = @"远程视频地址";
            }else {
                textField.text = g_downloadAddress;
            }
            textField.keyboardType = UIKeyboardTypeURL;
        }];
        UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            // 响应事件 得到文字内容
            g_downloadAddress = alert.textFields[0].text;
            NSString *resultStr = @"便捷模式已更改为从远程下载\n\n需要保证是一个可访问视频地址\n\n完成后会有系统的静音提示\n下载失败禁用替换";
            if ([g_downloadAddress isEqual:@""]) {
                resultStr = @"便捷模式已改为从相册选取";
            }
            UIAlertController* resultAlert = [UIAlertController alertControllerWithTitle:@"便捷模式更改" message:resultStr preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *ok = [UIAlertAction actionWithTitle:@"了解" style:UIAlertActionStyleDefault handler:nil];
            [resultAlert addAction:ok];
            [[GetFrame getKeyWindow].rootViewController presentViewController:resultAlert animated:YES completion:nil];
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:okAction];
        [alert addAction:cancel];
        [[GetFrame getKeyWindow].rootViewController presentViewController:alert animated:YES completion:nil];
    }];
    UIAlertAction *cancelReplace = [UIAlertAction actionWithTitle:@"禁用替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
    }];

    NSString *isMirroredText = @"尝试修复拍照翻转";
    if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) isMirroredText = @"尝试修复拍照翻转 ✅";
    UIAlertAction *isMirrored = [UIAlertAction actionWithTitle:isMirroredText style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            [g_fileManager removeItemAtPath:g_isMirroredMark error:nil];
        }else {
            [g_fileManager createDirectoryAtPath:g_isMirroredMark withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消操作" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *showHelp = [UIAlertAction actionWithTitle:@"- 查看帮助 -" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSURL *URL = [NSURL URLWithString:@"https://github.com/trizau/iOS-VCAM"];
        [[UIApplication sharedApplication]openURL:URL];
    }];

    [alertController addAction:next];
    [alertController addAction:download];
    [alertController addAction:cancelReplace];
    [alertController addAction:cancel];
    [alertController addAction:showHelp];
    [alertController addAction:isMirrored];

    g_currentMenu = alertController;
    [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];
}

// 三指长按：打开菜单 / 关闭菜单
void ui_toggleMenu(){
    UIViewController *rootVC = [GetFrame getKeyWindow].rootViewController;
    if (g_currentMenu != nil && rootVC.presentedViewController == g_currentMenu) {
        [g_currentMenu dismissViewControllerAnimated:YES completion:^{
            g_currentMenu = nil;
        }];
        return;
    }
    g_currentMenu = nil;
    ui_showMenu();
}

// 三指长按手势检测：在注入的 App 内拦截所有触摸事件
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    // 统计当前仍处于按下状态的手指数量
    NSSet *touches = [event touchesForWindow:self];
    NSUInteger pressed = 0;
    for (UITouch *t in touches) {
        if (t.phase == UITouchPhaseBegan || t.phase == UITouchPhaseMoved || t.phase == UITouchPhaseStationary) {
            pressed++;
        }
    }

    static BOOL g_threeFingerTriggered = NO;
    static NSTimeInterval g_threeFingerPressTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (pressed >= 3) { // 三指同时按住
        if (g_threeFingerPressTime == 0) g_threeFingerPressTime = now;
        if (!g_threeFingerTriggered && (now - g_threeFingerPressTime) >= 0.6) { // 长按 0.6 秒触发一次
            g_threeFingerTriggered = YES;
            ui_toggleMenu();
        }
    } else {
        if (pressed == 0) { // 手指全部抬起后复位，允许再次触发
            g_threeFingerPressTime = 0;
            g_threeFingerTriggered = NO;
        }
    }
    %orig;
}
%end


// ============ QQ 视频通话适配 ============
// 逆向结论：QQ 视频通话摄像头采集走标准 AVFoundation（AVCaptureSession +
// AVCaptureVideoDataOutput + AVCaptureVideoDataOutputSampleBufferDelegate），
// VCAM 的通用帧替换对 QQ 视频通话已直接生效；此处仅在“拨打视频电话”入口
// 确保替换视频已就位（没选过则先弹菜单选择，选完自动继续拨号）。

static IMP g_qqStartAVCallOriginal = NULL; // VideoChatService startAVCallWithModel: 原实现
static id g_qqPendingCallModel = nil;      // 被暂存的待拨号 model（等用户选完视频）
static id g_qqCallSelf = nil;              // 发起拨号时的 VideoChatService 实例
static BOOL g_qqCallHookInstalled = NO;

// 用户选完替换视频后，继续执行被暂存的拨号
void qq_continuePendingCall(void) {
    if (g_qqPendingCallModel == nil || g_qqStartAVCallOriginal == NULL) return;
    id model = g_qqPendingCallModel;
    id self = g_qqCallSelf;
    IMP orig = g_qqStartAVCallOriginal;
    g_qqPendingCallModel = nil;
    g_qqCallSelf = nil;
    g_qqStartAVCallOriginal = NULL;
    if (self != nil && orig != NULL) {
        ((void(*)(id, SEL, id))orig)(self, @selector(startAVCallWithModel:), model);
    }
}

// 判断本次是否为语音通话（语音直接拨，不弹菜单）。
// 通过 model 的 description 里常见标志位做启发式判断；默认返回 NO（按视频处理，弹菜单更安全）。
static BOOL qq_isVoiceCall(id model) {
    @try {
        NSString *desc = [NSString stringWithFormat:@"%@", model];
        NSArray *voiceMarks = @[@"isAudio = 1", @"isAudioCall = 1", @"audioOnly", @"isVoice = 1",
                                @"isVoiceCall = 1", @"callType = 1", @"callType=1", @"audio = YES",
                                @"isAudio = YES", @"mediaType = 0", @"mediaType=0"];
        for (NSString *m in voiceMarks) {
            if ([desc containsString:m]) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// 视频通话操作菜单：直接拨打 / 选择视频素材 / 取消
static void qq_showCallActionMenu(void) {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"ARvideo"
                                                                  message:@"选择拨号方式\n客服QQ：204325164"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertAction *direct = [UIAlertAction actionWithTitle:@"直接拨打" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        IMP orig = g_qqStartAVCallOriginal;
        id model = g_qqPendingCallModel;
        id slf = g_qqCallSelf;
        g_qqPendingCallModel = nil; g_qqCallSelf = nil; g_qqStartAVCallOriginal = NULL;
        if (orig && slf && model) ((void(*)(id, SEL, id))orig)(slf, @selector(startAVCallWithModel:), model);
    }];
    UIAlertAction *pick = [UIAlertAction actionWithTitle:@"选择视频素材" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        ui_selectVideo(); // 选完会自动调 qq_continuePendingCall 继续拨号
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        g_qqPendingCallModel = nil; g_qqCallSelf = nil; g_qqStartAVCallOriginal = NULL; // 放弃本次拨号
    }];
    [menu addAction:direct];
    [menu addAction:pick];
    [menu addAction:cancel];
    UIViewController *rootVC = [GetFrame getKeyWindow].rootViewController;
    [rootVC presentViewController:menu animated:YES completion:nil];
}

// 动态挂钩 QQ 的 VideoChatService：拨号前确保替换视频已就位
static void qq_installCallHook(void) {
    if (g_qqCallHookInstalled) return;
    Class vcs = NSClassFromString(@"VideoChatService");
    if (vcs == nil) return;
    __block void (*orig)(id, SEL, id) = NULL;
    MSHookMessageEx(
        vcs, @selector(startAVCallWithModel:),
        imp_implementationWithBlock(^(id self, id model) {
            // 语音通话：直接拨打，不弹任何菜单
            if (qq_isVoiceCall(model)) {
                if (orig) orig(self, @selector(startAVCallWithModel:), model);
                return;
            }
            // 视频通话：暂存拨号，弹操作菜单（直接拨打 / 选择视频素材 / 取消）
            g_qqStartAVCallOriginal = (IMP)orig;
            g_qqPendingCallModel = model;
            g_qqCallSelf = self;
            qq_showCallActionMenu();
        }), (IMP*)&orig
    );
    g_qqCallHookInstalled = YES;
}



%ctor {
	NSLog(@"我被载入成功啦");
    g_fileManager = [NSFileManager defaultManager];
    g_pasteboard = [UIPasteboard generalPasteboard];

    // roothide/rootless 下不再依赖 /var/mobile 全局路径，改用进程自己的 Caches 目录（一定可写）
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheDir == nil) cacheDir = NSTemporaryDirectory();
    g_tempFile = [cacheDir stringByAppendingPathComponent:@"temp.mov"];
    g_isMirroredMark = [cacheDir stringByAppendingPathComponent:@"vcam_is_mirrored_mark"];

    // QQ 视频通话适配：挂钩 VideoChatService，拨打视频电话前确保已选替换视频
    qq_installCallHook();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        qq_installCallHook();
    });
}

%dtor{
    g_fileManager = nil;
    g_pasteboard = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    NSLog(@"卸载完成了");
}