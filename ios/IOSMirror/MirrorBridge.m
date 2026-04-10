@import React;
@import React.RCTBridge_Private;

@interface RCT_EXTERN_MODULE(MirrorBridge, RCTEventEmitter)

RCT_EXTERN_METHOD(startDiscovery)
RCT_EXTERN_METHOD(stopDiscovery)

RCT_EXTERN_METHOD(startMirror:(NSString *)deviceID
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stopMirror:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

@end
