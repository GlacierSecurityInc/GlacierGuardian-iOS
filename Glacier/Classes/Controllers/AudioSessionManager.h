//
//  AudioSessionManager.h
//  ChatSecure
//
//  Created by David Chiles on 1/30/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;

@class AudioSessionManager;

@protocol AudioSessionManagerDelegate <NSObject>

@optional
- (void)audioSession:(AudioSessionManager *)audioSessionManager didFinishWithError:(NSError *)error;
- (void)audioSessionDidStartPlaying:(AudioSessionManager *)sessionManager;

- (void)audioSession:(AudioSessionManager *)audioSessionManager didUpdateRecordingDecibel:(double)decibel;
@end

@interface AudioSessionManager : NSObject

@property (nonatomic, readonly) BOOL isPlaying;

@property (nonatomic, weak) id<AudioSessionManagerDelegate> delegate;

- (void)playAudioWithURL:(NSURL *)url error:(NSError **)error;
- (void)pausePlaying;
- (void)resumePlaying;
- (void)stopPlaying;
- (NSTimeInterval)currentTimePlayTime;
- (NSTimeInterval)durationPlayTime;
- (NSURL *)currentPlayerURL;
- (BOOL)isPlaying;

- (void)recordAudioToURL:(NSURL *)url error:(NSError **)error;
- (void)stopRecording;
- (NSTimeInterval)currentTimeRecordTime;
- (NSURL *)currentRecorderURL;
- (BOOL)isRecording;

@end
