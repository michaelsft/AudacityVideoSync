/*
 * Audacity Video Sync — native video synchronisation companion for Audacity.
 * Copyright © 2026 Audacity Video Sync contributors.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MPVPlayerView : NSOpenGLView

@property(nonatomic, readonly, getter=isPlayerReady) BOOL playerReady;

- (BOOL)startPlayer:(NSError **)error;
- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)setPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)setMuted:(BOOL)muted error:(NSError **)error;
- (BOOL)setTimePosition:(double)seconds error:(NSError **)error;
- (BOOL)setPlaybackRate:(double)rate error:(NSError **)error;
- (double)timePosition;
- (double)duration;
- (BOOL)isPaused;
- (void)shutdownPlayer;

@end

NS_ASSUME_NONNULL_END
