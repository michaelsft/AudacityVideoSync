/*
 * Audacity Video Sync — native video synchronisation companion for Audacity.
 * Copyright © 2026 Audacity Video Sync contributors.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MPVPlayerView.h"

#import <OpenGL/gl.h>
#import <mpv/client.h>
#import <mpv/render.h>
#import <mpv/render_gl.h>

static NSString *const MPVPlayerErrorDomain = @"com.gothicstorm.audacityvideosync.mpv";

static void *getOpenGLProcAddress(void *context, const char *name) {
    CFStringRef symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    CFBundleRef openGLBundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    void *address = openGLBundle ? CFBundleGetFunctionPointerForName(openGLBundle, symbolName) : NULL;
    CFRelease(symbolName);
    return address;
}

static void requestRender(void *context) {
    MPVPlayerView *view = (__bridge MPVPlayerView *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) {
            view.needsDisplay = YES;
        }
    });
}

static void wakeMPVEventLoop(void *context) {
    MPVPlayerView *view = (__bridge MPVPlayerView *)context;
    [view performSelector:@selector(scheduleEventDrain)];
}

@interface MPVPlayerView () {
    mpv_handle *_mpv;
    mpv_render_context *_renderContext;
    dispatch_queue_t _eventQueue;
    BOOL _shuttingDown;
}
- (void)scheduleEventDrain;
- (void)drainEvents;
@end

@implementation MPVPlayerView

- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFANoRecovery,
        0,
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    self = [super initWithFrame:frameRect pixelFormat:format];
    if (self) {
        self.wantsBestResolutionOpenGLSurface = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _eventQueue = dispatch_queue_create("com.gothicstorm.audacityvideosync.mpv-events", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (BOOL)isPlayerReady {
    return _mpv != NULL && _renderContext != NULL && !_shuttingDown;
}

- (NSError *)errorForStatus:(int)status action:(NSString *)action {
    const char *message = mpv_error_string(status);
    NSString *description = message ? [NSString stringWithUTF8String:message] : @"Unknown mpv error";
    return [NSError errorWithDomain:MPVPlayerErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", action, description]}];
}

- (BOOL)applyStatus:(int)status action:(NSString *)action error:(NSError **)error {
    if (status >= 0) {
        return YES;
    }
    if (error) {
        *error = [self errorForStatus:status action:action];
    }
    return NO;
}

- (BOOL)startPlayer:(NSError **)error {
    if (self.playerReady) {
        return YES;
    }

    [[self openGLContext] makeCurrentContext];
    GLint swapInterval = 1;
    [[self openGLContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];

    _mpv = mpv_create();
    if (!_mpv) {
        if (error) {
            *error = [NSError errorWithDomain:MPVPlayerErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create the mpv playback engine."}];
        }
        return NO;
    }

    const char *options[][2] = {
        {"config", "no"},
        {"terminal", "no"},
        {"input-default-bindings", "no"},
        {"input-media-keys", "no"},
        {"osc", "no"},
        {"vo", "libmpv"},
        {"keep-open", "always"},
        {"pause", "yes"},
        {"mute", "yes"},
        {"hwdec", "auto-safe"},
    };
    for (NSUInteger index = 0; index < sizeof(options) / sizeof(options[0]); index++) {
        int status = mpv_set_option_string(_mpv, options[index][0], options[index][1]);
        if (![self applyStatus:status action:@"Could not configure mpv" error:error]) {
            mpv_terminate_destroy(_mpv);
            _mpv = NULL;
            return NO;
        }
    }

    int status = mpv_initialize(_mpv);
    if (![self applyStatus:status action:@"Could not initialize mpv" error:error]) {
        mpv_terminate_destroy(_mpv);
        _mpv = NULL;
        return NO;
    }

    mpv_opengl_init_params openGLParams = {
        .get_proc_address = getOpenGLProcAddress,
        .get_proc_address_ctx = NULL,
    };
    mpv_render_param renderParams[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &openGLParams},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };

    status = mpv_render_context_create(&_renderContext, _mpv, renderParams);
    if (![self applyStatus:status action:@"Could not create the mpv video renderer" error:error]) {
        mpv_terminate_destroy(_mpv);
        _mpv = NULL;
        return NO;
    }

    mpv_render_context_set_update_callback(_renderContext, requestRender, (__bridge void *)self);
    mpv_set_wakeup_callback(_mpv, wakeMPVEventLoop, (__bridge void *)self);
    self.needsDisplay = YES;
    return YES;
}

- (void)scheduleEventDrain {
    __weak MPVPlayerView *weakSelf = self;
    dispatch_async(_eventQueue, ^{
        [weakSelf drainEvents];
    });
}

- (void)drainEvents {
    while (_mpv && !_shuttingDown) {
        mpv_event *event = mpv_wait_event(_mpv, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) {
            break;
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [[self openGLContext] makeCurrentContext];
    if (_renderContext && !_shuttingDown) {
        NSRect backingBounds = [self convertRectToBacking:self.bounds];
        mpv_opengl_fbo framebuffer = {
            .fbo = 0,
            .w = MAX(1, (int)backingBounds.size.width),
            .h = MAX(1, (int)backingBounds.size.height),
            .internal_format = 0,
        };
        int flip = 1;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &framebuffer},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, NULL},
        };
        mpv_render_context_render(_renderContext, params);
    } else {
        glClearColor(0.035f, 0.047f, 0.045f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    [[self openGLContext] flushBuffer];
    if (_renderContext && !_shuttingDown) {
        mpv_render_context_report_swap(_renderContext);
    }
}

- (void)reshape {
    [super reshape];
    self.needsDisplay = YES;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    if (!self.playerReady) {
        if (error) {
            *error = [NSError errorWithDomain:MPVPlayerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"The mpv player is not ready."}];
        }
        return NO;
    }
    int paused = 1;
    mpv_set_property(_mpv, "pause", MPV_FORMAT_FLAG, &paused);
    const char *command[] = {"loadfile", path.fileSystemRepresentation, "replace", NULL};
    int status = mpv_command(_mpv, command);
    if (![self applyStatus:status action:@"Could not load the video" error:error]) {
        return NO;
    }
    mpv_set_property(_mpv, "pause", MPV_FORMAT_FLAG, &paused);
    return YES;
}

- (BOOL)setPaused:(BOOL)paused error:(NSError **)error {
    if (!_mpv || _shuttingDown) return NO;
    int flag = paused ? 1 : 0;
    return [self applyStatus:mpv_set_property(_mpv, "pause", MPV_FORMAT_FLAG, &flag)
                       action:@"Could not change playback state"
                        error:error];
}

- (BOOL)setMuted:(BOOL)muted error:(NSError **)error {
    if (!_mpv || _shuttingDown) return NO;
    int flag = muted ? 1 : 0;
    return [self applyStatus:mpv_set_property(_mpv, "mute", MPV_FORMAT_FLAG, &flag)
                       action:@"Could not change audio mute state"
                        error:error];
}

- (BOOL)setTimePosition:(double)seconds error:(NSError **)error {
    if (!_mpv || _shuttingDown) return NO;
    double position = MAX(0.0, seconds);
    return [self applyStatus:mpv_set_property(_mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
                       action:@"Could not seek the video"
                        error:error];
}

- (BOOL)setPlaybackRate:(double)rate error:(NSError **)error {
    if (!_mpv || _shuttingDown) return NO;
    double safeRate = MAX(0.25, MIN(4.0, rate));
    return [self applyStatus:mpv_set_property(_mpv, "speed", MPV_FORMAT_DOUBLE, &safeRate)
                       action:@"Could not change playback speed"
                        error:error];
}

- (double)doubleProperty:(const char *)name {
    if (!_mpv || _shuttingDown) return 0.0;
    double value = 0.0;
    return mpv_get_property(_mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : 0.0;
}

- (double)timePosition {
    return [self doubleProperty:"time-pos"];
}

- (double)duration {
    return [self doubleProperty:"duration"];
}

- (BOOL)isPaused {
    if (!_mpv || _shuttingDown) return YES;
    int paused = 1;
    return mpv_get_property(_mpv, "pause", MPV_FORMAT_FLAG, &paused) >= 0 ? paused != 0 : YES;
}

- (void)shutdownPlayer {
    if (_shuttingDown) return;
    _shuttingDown = YES;

    if (_mpv) {
        mpv_set_wakeup_callback(_mpv, NULL, NULL);
        dispatch_sync(_eventQueue, ^{});
    }
    if (_renderContext) {
        mpv_render_context_set_update_callback(_renderContext, NULL, NULL);
        [[self openGLContext] makeCurrentContext];
        mpv_render_context_free(_renderContext);
        _renderContext = NULL;
    }
    if (_mpv) {
        mpv_terminate_destroy(_mpv);
        _mpv = NULL;
    }
    [self clearGLContext];
}

- (void)dealloc {
    [self shutdownPlayer];
}

@end
