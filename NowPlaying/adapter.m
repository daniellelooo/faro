// Adaptador de "Ahora suena" para Dicta. Se carga dentro de /usr/bin/perl (binario de Apple), porque desde
// macOS 15.4 el framework privado MediaRemote solo responde a binarios de la plataforma.
// Escribe una línea JSON por cambio en stdout. Implementación propia de Dicta.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static void *mr(void) {
  static void *h = NULL;
  if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
  return h;
}

static NSString *lastArtworkHash = nil;

static void emit(void) {
  GetInfoFn getInfo = (GetInfoFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingInfo");
  GetPlayingFn getPlaying = (GetPlayingFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
  GetPIDFn getPID = (GetPIDFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingApplicationPID");
  if (!getInfo || !getPlaying) return;
  dispatch_queue_t q = dispatch_get_main_queue();
  getInfo(q, ^(CFDictionaryRef cfInfo) {
    NSDictionary *info = (__bridge NSDictionary *)cfInfo;
    getPlaying(q, ^(Boolean playing) {
      void (^finish)(int) = ^(int pid) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"playing"] = @(playing ? YES : NO);
        if (info) {
          id v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) out[@"title"] = v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) out[@"artist"] = v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) out[@"album"] = v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) out[@"duration"] = v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) out[@"elapsed"] = v;
          if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) out[@"rate"] = v;
          NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
          if (ts) out[@"timestamp"] = @([ts timeIntervalSince1970]);
          NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
          if (art.length > 0) {
            NSString *hash = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
            out[@"artworkId"] = hash;
            // La carátula solo se manda cuando cambia (puede pesar cientos de KB).
            if (![hash isEqualToString:lastArtworkHash]) {
              out[@"artwork"] = [art base64EncodedStringWithOptions:0];
              lastArtworkHash = hash;
            }
          }
        }
        if (pid > 0) {
          out[@"pid"] = @(pid);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (json) {
          fwrite(json.bytes, 1, json.length, stdout);
          fputc('\n', stdout);
          fflush(stdout);
        }
      };
      if (getPID) getPID(q, ^(int pid) { finish(pid); }); else finish(0);
    });
  });
}

// Imprime el estado una vez y termina.
void dicta_now_playing_get(void) {
  emit();
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
}

// Escucha cambios para siempre (Dicta lee stdout). Comandos por stdin: "toggle", "next", "previous", "seek <s>".
void dicta_now_playing_watch(void) {
  RegisterFn reg = (RegisterFn)dlsym(mr(), "MRMediaRemoteRegisterForNowPlayingNotifications");
  if (reg) reg(dispatch_get_main_queue());
  NSArray *names = @[
    @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
    @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
  ];
  for (NSString *n in names) {
    [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) { emit(); }];
  }
  SendCommandFn send = (SendCommandFn)dlsym(mr(), "MRMediaRemoteSendCommand");
  SetElapsedFn setElapsed = (SetElapsedFn)dlsym(mr(), "MRMediaRemoteSetElapsedTime");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
      NSString *cmd = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([cmd isEqualToString:@"toggle"] && send) send(2, NULL);
        else if ([cmd isEqualToString:@"next"] && send) send(4, NULL);
        else if ([cmd isEqualToString:@"previous"] && send) send(5, NULL);
        else if ([cmd isEqualToString:@"shuffle"] && send) send(6, NULL);
        else if ([cmd isEqualToString:@"repeat"] && send) send(7, NULL);
        else if ([cmd hasPrefix:@"seek "] && setElapsed) setElapsed([[cmd substringFromIndex:5] doubleValue]);
        else if ([cmd isEqualToString:@"refresh"]) emit();
      });
    }
    exit(0);
  });
  emit();
  CFRunLoopRun();
}
